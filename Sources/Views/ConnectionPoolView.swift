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

/// Cross-platform gray background color
private extension Color {
    static var systemGray6Color: Color {
        #if canImport(UIKit)
        return Color(.systemGray6)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var systemGray5Color: Color {
        #if canImport(UIKit)
        return Color(.systemGray5)
        #else
        return Color(nsColor: .separatorColor)
        #endif
    }

    static var systemBackgroundColor: Color {
        #if canImport(UIKit)
        return Color(.systemBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

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
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
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

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Pool Chat")
                .font(.title.bold())

            Text("Chat is available as a standalone app.\nOpen Pool Chat from the App Launcher.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                viewModel.currentView = .lobby
            } label: {
                Text("Back to Lobby")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
            }
        }
        .padding()
    }
}

// MARK: - Home View

private struct HomeView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @State private var showRemoteHostSheet = false

    @State private var showDeleteServerAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Profile button in top right
                HStack {
                    Spacer()
                    ProfileButton(viewModel: viewModel)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                // App Icon & Title
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .purple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)

                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 36))
                            .foregroundStyle(.white)
                    }

                    Text("Connection Pool")
                        .font(.title.bold())

                    Text("Connect with nearby devices...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Action Buttons
                VStack(spacing: 16) {
                    // Host Pool Button
                    Button {
                        viewModel.currentView = .lobby
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "wifi.circle.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Host Pool")
                                    .font(.headline)
                                Text("Create a new pool for others to join")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Join Pool Button
                    Button {
                        viewModel.startBrowsing()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Join Pool")
                                    .font(.headline)
                                Text("Find and join nearby pools")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(
                            LinearGradient(
                                colors: [.green, .green.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal)

                // Saved Remote Server (if claimed)
                if let saved = RemotePoolState.load(), saved.isClaimed {
                    VStack(spacing: 8) {
                        HStack {
                            Button {
                                viewModel.createRemotePool(serverURL: saved.serverURL)
                            } label: {
                                HStack {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(saved.poolName.isEmpty ? "My Server" : saved.poolName)
                                            .font(.subheadline.bold())
                                        Text(saved.serverURL)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)

                            Button {
                                viewModel.startEditingServerURL(from: saved.serverURL)
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.subheadline)
                                    .foregroundStyle(.blue)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                showDeleteServerAlert = true
                            } label: {
                                Image(systemName: "trash")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                        .background(Color.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                VStack(spacing: 12) {
                    Text("Remote Pool")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        Button(action: { showRemoteHostSheet = true }) {
                            Label("Host Remote Pool", systemImage: "server.rack")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: { viewModel.showRemoteJoinSheet = true }) {
                            Label("Join via Invitation", systemImage: "link")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.top, 4)

                // Info Section
                HStack(spacing: 16) {
                    InfoBadge(icon: "lock.fill", text: "Encrypted")
                    InfoBadge(icon: "wifi.slash", text: "No Internet")
                    InfoBadge(icon: "person.3.fill", text: "Up to 8")
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .padding()
        }
        .alert("Remove Server", isPresented: $showDeleteServerAlert) {
            Button("Remove", role: .destructive) {
                RemotePoolState.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the saved relay server. You can re-add it later by claiming the server again.")
        }
        .alert("Edit Server URL", isPresented: $viewModel.showEditServerURL) {
            TextField("wss://relay.example.com", text: $viewModel.editingServerURL)
                .crossPlatformTextField()
            Button("Save") {
                viewModel.updateServerURL(viewModel.editingServerURL)
            }
            Button("Cancel", role: .cancel) {
                viewModel.showEditServerURL = false
            }
        } message: {
            Text("Enter the new relay server URL. Use your tunnel URL (wss://) so friends outside your network can connect.")
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
                Text("No invitation available").padding()
            }
        }
    }
}

// MARK: - Info Badge

private struct InfoBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.systemGray6Color)
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

    /// Shared relative formatter — instantiating `RelativeDateTimeFormatter` is cheap but
    /// repeating it on every body re-render isn't free, so it lives in a static.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
                Text("New invitations are paused until the host comes back. Existing chat, calls, and tunneling keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if let offlineSince {
            let suffix = Self.relativeFormatter.localizedString(for: offlineSince, relativeTo: Date())
            return "Host offline · \(suffix)"
        } else {
            return "Host offline"
        }
    }
}

// MARK: - Browse Pools View

private struct BrowsePoolsView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                }

                Spacer()

                Text("Nearby Pools")
                    .font(.headline)

                Spacer()

                // Refresh button
                Button {
                    viewModel.refreshBrowsing()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title3)
                }
            }
            .padding()
            .background(Color.systemGray6Color)

            // Scanning indicator
            if viewModel.poolState == .browsing && viewModel.discoveredPeers.isEmpty {
                VStack(spacing: 16) {
                    Spacer()

                    // Animated scanning indicator
                    ZStack {
                        ForEach(0..<3) { index in
                            Circle()
                                .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                                .frame(width: CGFloat(60 + index * 40), height: CGFloat(60 + index * 40))
                        }

                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 30))
                            .foregroundStyle(.blue)
                    }

                    Text("Scanning for nearby pools...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Make sure other devices are hosting\na Connection Pool nearby")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Spacer()
                }
            } else if viewModel.discoveredPeers.isEmpty {
                VStack(spacing: 16) {
                    Spacer()

                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)

                    Text("No pools found")
                        .font(.headline)

                    Text("Ask someone to host a pool\nor try again later")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        viewModel.refreshBrowsing()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Scan Again")
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .foregroundStyle(.white)
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
        .crossPlatformNavigationBarHidden(true)
    }
}

// MARK: - Discovered Pool Row

private struct DiscoveredPoolRow: View {
    let peer: DiscoveredPeer
    let onJoin: () -> Void

    private var avatarColor: Color {
        PoolUserProfile.availableColors[peer.avatarColorIndex % PoolUserProfile.availableColors.count]
    }

    var body: some View {
        HStack(spacing: 12) {
            // Host avatar (shows emoji if profile available, otherwise icon)
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.2))
                    .frame(width: 50, height: 50)

                if let emoji = peer.avatarEmoji {
                    Text(emoji)
                        .font(.system(size: 24))
                } else {
                    Image(systemName: "wifi.circle.fill")
                        .font(.title2)
                        .foregroundStyle(avatarColor)
                }
            }

            // Pool info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(peer.displayName)
                        .font(.headline)

                    // Show lock icon if pool requires code
                    if peer.hasPoolCode {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                HStack(spacing: 8) {
                    // Show host name if profile available
                    if let hostName = peer.hostProfile?.displayName {
                        Label(hostName, systemImage: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label(peer.id, systemImage: "iphone")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Join button
            if peer.isInviting {
                VStack(spacing: 4) {
                    ProgressView()
                    Text("Joining...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    onJoin()
                } label: {
                    Text("Join")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Pool Lobby View

private struct PoolLobbyView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @State private var showHostSettings = false
    @State private var showInviteSheet = false

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
                Text("No invitation available").padding()
            }
        }
        .alert("Edit Server URL", isPresented: $viewModel.showEditServerURL) {
            TextField("wss://relay.example.com", text: $viewModel.editingServerURL)
                .crossPlatformTextField()
            Button("Save") {
                viewModel.updateServerURL(viewModel.editingServerURL)
            }
            Button("Cancel", role: .cancel) {
                viewModel.showEditServerURL = false
            }
        } message: {
            Text("Enter the new relay server URL. Use your tunnel URL (wss://) so friends outside your network can connect.")
        }
    }

    private var lobbyHeader: some View {
        HStack {
            Button {
                viewModel.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }

            Spacer()

            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(headerStatusColor)
                        .frame(width: 8, height: 8)
                    Text(headerStatusText)
                        .font(.headline)
                }
                if let session = viewModel.currentSession {
                    Text(session.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isInHostSetupMode {
                Button {
                    showHostSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                }
            } else {
                Image(systemName: "gearshape")
                    .font(.title3)
                    .opacity(0)
            }
        }
        .padding()
        .background(Color.systemGray6Color)
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
            return "Setup"
        case .hosting:
            let peerCount = viewModel.connectedPeers.count
            // Subtract 1 for host themselves
            let guestCount = max(0, peerCount - 1)
            if guestCount == 0 {
                return "Hosting - Waiting"
            } else {
                return "Hosting"
            }
        case .browsing:
            return "Browsing"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .error:
            return "Error"
        }
    }

    /// Header status color reflecting the actual connection state
    private var headerStatusColor: Color {
        let state = viewModel.poolState
        switch state {
        case .idle:
            return .gray
        case .hosting:
            let peerCount = viewModel.connectedPeers.count
            let guestCount = max(0, peerCount - 1)
            // Yellow/orange when waiting for participants, green when connected
            return guestCount == 0 ? .orange : .green
        case .browsing, .connecting:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
        }
    }
}

// MARK: - Host Setup View

private struct HostSetupView: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Pool Name
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pool Name")
                        .font(.headline)

                    TextField("Enter pool name", text: $viewModel.poolName)
                        .textFieldStyle(.roundedBorder)
                }

                // Max Peers
                VStack(alignment: .leading, spacing: 8) {
                    Text("Maximum Participants")
                        .font(.headline)

                    Picker("Max Peers", selection: $viewModel.maxPeers) {
                        ForEach(2...8, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Options
                VStack(spacing: 12) {
                    Toggle(isOn: $viewModel.requireEncryption) {
                        HStack {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.green)
                            Text("Require Encryption")
                        }
                    }

                    Toggle(isOn: $viewModel.autoAcceptPeers) {
                        HStack {
                            Image(systemName: "person.badge.plus")
                                .foregroundStyle(.blue)
                            Text("Auto-accept Join Requests")
                        }
                    }
                }
                .padding()
                .background(Color.systemGray6Color)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Start Hosting Button
                Button {
                    viewModel.startHosting()
                } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Start Hosting")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
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

    var body: some View {
        VStack(spacing: 12) {
            Text("Share this code to invite others")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(code)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(.primary)

            Button {
                CrossPlatformClipboard.copyToClipboard(code)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copied = false
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied!" : "Copy Code")
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(copied ? Color.green : Color.blue)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.systemGray6Color)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Server URL Card

private struct ServerURLCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(.blue)
                Text("Relay Server")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    viewModel.startEditingServerURL()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("Edit")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Text(viewModel.serverURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let confirmation = viewModel.serverURLUpdateConfirmation {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(confirmation)
                        .foregroundStyle(.green)
                }
                .font(.caption)
                .transition(.opacity)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.systemGray6Color)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.hostTunnelExitEnabled ? "shield.checkerboard" : "shield.lefthalf.filled")
                    .foregroundStyle(viewModel.hostTunnelExitEnabled ? Color.green : Color.accentColor)
                Text("Allow Members to Use Relay Exit")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { viewModel.hostTunnelExitEnabled },
                    set: { newValue in
                        Task { await viewModel.setHostTunnelExitEnabled(newValue) }
                    }
                ))
                .labelsHidden()
            }

            if viewModel.hostTunnelExitEnabled {
                Text("Members of this pool can route their browser traffic through the relay server's internet connection. The relay's IP becomes the exit address — your phone is not in the data path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("When enabled, members of this pool can route their browser traffic through the relay's internet connection. The relay must also have tunnel-exit turned on in its server config for this to take effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.memberRelayActive ? "shield.checkerboard" : "shield.lefthalf.filled")
                    .foregroundStyle(viewModel.memberRelayActive ? Color.green : Color.accentColor)
                Text("Tunnel Through Host")
                    .font(.headline)
                Spacer()
            }

            if viewModel.memberRelayActive {
                if let name = viewModel.memberRelayHostName {
                    Text("Tunnelling through \(name)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tunnelling active")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    Task { await viewModel.onStopMemberRelayMode?() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.memberRelayPending {
                            ProgressView().controlSize(.small)
                            Text("Disconnecting…")
                        } else {
                            Text("Stop Tunnelling")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.memberRelayPending)
            } else {
                Text("Route your browser traffic through the relay server. Useful when you want a different exit IP than your home network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await viewModel.onStartMemberRelayMode?() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.memberRelayPending {
                            ProgressView().controlSize(.small).tint(.white)
                            Text("Connecting to relay…")
                        } else {
                            Text("Tunnel My Traffic Through Relay")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.memberRelayPending)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ConnectionStatusCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel

    var body: some View {
        HStack {
            // Status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(statusText)
                    .font(.subheadline)
            }

            Spacer()

            // Encryption badge
            if viewModel.currentSession?.isEncrypted == true {
                HStack(spacing: 4) {
                    Image(systemName: "lock.fill")
                    Text("Encrypted")
                }
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.green.opacity(0.15))
                .clipShape(Capsule())
            }
        }
        .padding()
        .background(Color.systemGray6Color)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
            return "Not Connected"
        case .hosting:
            if guestCount == 0 {
                return "Hosting - Waiting for participants"
            } else {
                return "Hosting - \(guestCount) participant\(guestCount == 1 ? "" : "s")"
            }
        case .browsing:
            return "Looking for Pools"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private var statusColor: Color {
        switch viewModel.poolState {
        case .hosting:
            // Orange when waiting for participants, green when connected
            return guestCount == 0 ? .orange : .green
        case .connected:
            return .green
        case .connecting, .browsing:
            return .orange
        case .idle:
            return .gray
        case .error:
            return .red
        }
    }
}

// MARK: - Pending Invitations Card

private struct PendingInvitationsCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.badge.clock")
                    .foregroundStyle(.orange)
                Text("Pending Requests")
                    .font(.headline)

                Spacer()

                Text("\(viewModel.pendingInvitations.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }

            ForEach(viewModel.pendingInvitations) { invitation in
                HStack(spacing: 12) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.2))
                            .frame(width: 40, height: 40)

                        Text(String(invitation.displayName.prefix(1)).uppercased())
                            .font(.headline)
                            .foregroundStyle(.orange)
                    }

                    // Name
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.displayName)
                            .font(.subheadline.bold())
                        Text("Wants to join")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Block/Reject/Accept buttons
                    HStack(spacing: 8) {
                        Button {
                            viewModel.blockPendingPeer(invitation)
                        } label: {
                            Image(systemName: "hand.raised.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.orange)
                                .clipShape(Circle())
                        }

                        Button {
                            viewModel.rejectInvitation(invitation)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.red)
                                .clipShape(Circle())
                        }

                        Button {
                            viewModel.acceptInvitation(invitation)
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(Color.green)
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Participants Card

private struct ParticipantsCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel

    private let avatarColors: [Color] = [
        .red, .orange, .yellow, .green,
        .blue, .purple, .pink, .cyan
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Participants")
                    .font(.headline)

                Spacer()

                Text("\(viewModel.connectedPeers.count)/\(viewModel.currentSession?.maxPeers ?? 8)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.systemGray5Color)
                    .clipShape(Capsule())
            }

            if viewModel.connectedPeers.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "person.slash")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("No participants yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)
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
        .background(Color.systemGray6Color)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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

    private var avatarColor: Color {
        avatarColors[peer.avatarColorIndex % avatarColors.count]
    }

    var body: some View {
        HStack(spacing: 12) {
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
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }

            // Name & Status
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.effectiveDisplayName)
                        .font(.subheadline.bold())

                    if peer.isHost {
                        Text("HOST")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .clipShape(Capsule())
                    }

                    if isLocalPeer {
                        Text("YOU")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: hostShownAsOffline ? "wifi.slash" : peer.status.iconName)
                        .font(.caption2)
                    Text(hostShownAsOffline ? "Offline" : peer.status.displayText)
                        .font(.caption)
                }
                .foregroundStyle(
                    hostShownAsOffline
                        ? Color.secondary
                        : (peer.status == .connected ? Color.green : Color.secondary)
                )
            }

            Spacer()

            // Block & Kick buttons (for host, not for self or other host)
            if isHost && !isLocalPeer && !peer.isHost {
                Button {
                    onBlock()
                } label: {
                    Image(systemName: "hand.raised.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Circle())
                }

                Button {
                    onKick()
                } label: {
                    Image(systemName: "person.badge.minus")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .clipShape(Circle())
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Quick Actions Card

private struct QuickActionsCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @Binding var showInviteSheet: Bool
    @State private var showGamesSheet = false

    var body: some View {
        VStack(spacing: 12) {
            // Invite button (for host, local mode)
            if viewModel.isHost && viewModel.transportMode == .local {
                Button {
                    showInviteSheet = true
                } label: {
                    HStack {
                        Image(systemName: "person.badge.plus")
                            .font(.title3)
                        Text("Invite Peers")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
                        Image(systemName: "link.badge.plus")
                            .font(.title3)
                        Text("Invite a Friend")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .padding()
                    .background((inviteDisabled ? Color.gray : Color.green).opacity(0.1))
                    .foregroundStyle(inviteDisabled ? Color.gray : Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(inviteDisabled)

                if inviteDisabled {
                    Text("Host must be online to issue invitations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
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
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.title3)
                    Text("Open Pool Chat")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "arrow.up.forward.app")
                        .font(.caption)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .foregroundStyle(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Games button
            Button {
                showGamesSheet = true
            } label: {
                HStack {
                    Image(systemName: "gamecontroller.fill")
                        .font(.title3)
                    Text("Play Games")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                }
                .padding()
                .background(Color.purple.opacity(0.1))
                .foregroundStyle(.purple)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Blocked Devices button (host only)
            if viewModel.isHost {
                Button {
                    viewModel.blockedDevices = viewModel.poolManager.blockedDevices
                    viewModel.showBlockedDevicesSheet = true
                } label: {
                    HStack {
                        Image(systemName: "hand.raised.fill")
                            .font(.title3)
                        Text("Blocked Devices")
                            .font(.headline)
                        Spacer()
                        if !viewModel.blockedDevices.isEmpty {
                            Text("\(viewModel.blockedDevices.count)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
    @State private var showLeaveConfirmation = false

    private var isRemoteMember: Bool {
        viewModel.transportMode == .remote && !viewModel.isHost
    }

    var body: some View {
        Button {
            if isRemoteMember {
                showLeaveConfirmation = true
            } else {
                viewModel.disconnect()
            }
        } label: {
            HStack {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                Text(viewModel.isHost ? "Close Pool" : "Leave Pool")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color.red.opacity(0.1))
            .foregroundStyle(.red)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .alert("Leave this pool?", isPresented: $showLeaveConfirmation) {
            Button("Leave Pool", role: .destructive) {
                viewModel.leaveRemoteMemberPool()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need a new invitation to join again.")
        }
    }
}

// MARK: - Games Selection Sheet

private struct GamesSelectionSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header info
                VStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.purple)

                    Text("Multiplayer Games")
                        .font(.title2.bold())

                    Text("Challenge someone in your pool to a game!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)

                // Games list
                VStack(spacing: 12) {
                    // Chain Reaction
                    GameSelectionRow(
                        title: "Chain Reaction",
                        subtitle: "Place orbs and create chain reactions",
                        icon: "circle.hexagongrid.fill",
                        color: .orange,
                        players: "2 players"
                    ) {
                        viewModel.openGame(.chainReaction)
                        dismiss()
                    }

                    // Connect Four
                    GameSelectionRow(
                        title: "Connect Four",
                        subtitle: "Drop discs to connect 4 in a row",
                        icon: "circle.grid.3x3.fill",
                        color: .blue,
                        players: "2 players"
                    ) {
                        viewModel.openGame(.connectFour)
                        dismiss()
                    }

                    // Chess
                    GameSelectionRow(
                        title: "Chess",
                        subtitle: "The classic game of strategy",
                        icon: "crown.fill",
                        color: .brown,
                        players: "2 players"
                    ) {
                        viewModel.openGame(.chess)
                        dismiss()
                    }

                    // Prompt Party
                    GameSelectionRow(
                        title: "Prompt Party",
                        subtitle: "AI-powered party game with creative prompts",
                        icon: "bubble.left.and.bubble.right.fill",
                        color: .pink,
                        players: "2-8 players"
                    ) {
                        viewModel.openGame(.promptParty)
                        dismiss()
                    }

                    // Ludo
                    GameSelectionRow(
                        title: "Ludo",
                        subtitle: "Classic board game with dice rolling",
                        icon: "dice.fill",
                        color: .green,
                        players: "2-4 players"
                    ) {
                        viewModel.openGame(.ludo)
                        dismiss()
                    }
                }
                .padding(.horizontal)

                // Note about multiplayer
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Select \"vs Player\" mode in the game to play with pool members")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Play Games")
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
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
    let subtitle: String
    let icon: String
    let color: Color
    let players: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Image(systemName: icon)
                        .font(.system(size: 24))
                        .foregroundStyle(color)
                }

                // Info
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                        Text(players)
                            .font(.caption2)
                    }
                    .foregroundStyle(color)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.systemGray6Color)
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                Section("Pool Settings") {
                    TextField("Pool Name", text: $viewModel.poolName)

                    Picker("Max Participants", selection: $viewModel.maxPeers) {
                        ForEach(2...8, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                }

                Section("Security") {
                    Toggle("Require Encryption", isOn: $viewModel.requireEncryption)
                    Toggle("Auto-accept Join Requests", isOn: $viewModel.autoAcceptPeers)
                }

                // Note: the relay-exit toggle lives on the main pool detail page in
                // `TunnelExitHostCard`. The duplicate that used to live here was removed
                // so there is one canonical entry point.
            }
            .navigationTitle("Pool Settings")
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let invitation = viewModel.currentInvitation {
                    // Invitation icon
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.1))
                            .frame(width: 100, height: 100)

                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.blue)
                    }

                    // Invitation text
                    VStack(spacing: 8) {
                        Text("Join Request")
                            .font(.title2.bold())

                        Text("\(invitation.displayName) wants to join your pool")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer()

                    // Action buttons
                    VStack(spacing: 12) {
                        Button {
                            viewModel.acceptInvitation(invitation)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "checkmark")
                                Text("Accept")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }

                        Button {
                            viewModel.rejectInvitation(invitation)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "xmark")
                                Text("Decline")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.systemGray5Color)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                } else {
                    Text("No pending invitation")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle("")
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Dimmed background - tapping dismisses
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Modal card
            VStack(spacing: 20) {
                // Lock icon
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 72, height: 72)

                    Image(systemName: "lock.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                }

                // Title and pool name
                VStack(spacing: 6) {
                    Text("Enter Pool Code")
                        .font(.title3.bold())

                    Text("to join \"\(peer.displayName)\"")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Code input field
                VStack(spacing: 6) {
                    TextField("XXXXXX", text: $codeInput)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .crossPlatformTextField(autocapitalize: true)
                        .autocorrectionDisabled()
                        .focused($isCodeFieldFocused)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 20)
                        .background(Color.systemGray6Color)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onChange(of: codeInput) { _, newValue in
                            // Limit to 6 characters and uppercase
                            let filtered = String(newValue.uppercased().prefix(6))
                            if filtered != newValue {
                                codeInput = filtered
                            }
                        }

                    Text("Ask the host for the 6-character code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Action buttons
                HStack(spacing: 12) {
                    // Cancel button
                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.systemGray5Color)
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // Join button
                    Button {
                        onJoin()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                            Text("Join")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(codeInput.count == 6 ? Color.green : Color.gray)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(codeInput.count != 6)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(colorScheme == .dark ? Color.systemGray6Color : Color.systemBackgroundColor)
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Pool Code section
                if let poolCode = viewModel.currentSession?.poolCode {
                    VStack(spacing: 12) {
                        Text("Share this code")
                            .font(.headline)

                        Text(poolCode)
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                            .tracking(8)

                        Button {
                            CrossPlatformClipboard.copyToClipboard(poolCode)
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.doc")
                                Text("Copy Code")
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.systemGray6Color)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Divider()

                // Instructions
                VStack(alignment: .leading, spacing: 16) {
                    Text("How to invite")
                        .font(.headline)

                    InviteStep(number: 1, text: "Share the pool code with friends")
                    InviteStep(number: 2, text: "They open Connection Pool on their device")
                    InviteStep(number: 3, text: "They tap 'Join Pool' and find your pool")
                    InviteStep(number: 4, text: "Accept their join request")
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Invite Peers")
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .clipShape(Circle())

            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Blocked Devices Sheet

private struct BlockedDevicesSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.blockedDevices.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()

                        Image(systemName: "hand.raised.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)

                        Text("No Blocked Devices")
                            .font(.headline)

                        Text("Devices that are blocked from joining\nyour pool will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Spacer()
                    }
                } else {
                    List {
                        ForEach(viewModel.blockedDevices) { device in
                            HStack(spacing: 12) {
                                // Icon
                                ZStack {
                                    Circle()
                                        .fill(Color.orange.opacity(0.2))
                                        .frame(width: 40, height: 40)

                                    Image(systemName: "hand.raised.fill")
                                        .font(.subheadline)
                                        .foregroundStyle(.orange)
                                }

                                // Info
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.peerDisplayName)
                                        .font(.subheadline.bold())

                                    HStack(spacing: 6) {
                                        Text(device.reason == .bruteForce ? "Auto-blocked" : "Manually blocked")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        Text(device.blockedAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                // Unblock button
                                Button {
                                    viewModel.unblockDevice(device)
                                } label: {
                                    Text("Unblock")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.green)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Blocked Devices")
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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

    var body: some View {
        Button {
            viewModel.startEditingProfile()
        } label: {
            HStack(spacing: 8) {
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
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("Edit Profile")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.systemGray6Color)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Profile Settings Sheet

private struct ProfileSettingsSheet: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 8)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Avatar Preview
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(PoolUserProfile.availableColors[viewModel.editingProfileColorIndex])
                                .frame(width: 100, height: 100)
                                .shadow(color: PoolUserProfile.availableColors[viewModel.editingProfileColorIndex].opacity(0.4), radius: 8, x: 0, y: 4)

                            Text(viewModel.editingProfileEmoji)
                                .font(.system(size: 50))
                        }

                        Text("Your Pool Avatar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    // Display Name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display Name")
                            .font(.headline)

                        TextField("Enter your name", text: $viewModel.editingProfileName)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.horizontal)

                    // Avatar Emoji Picker
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Avatar Emoji")
                            .font(.headline)
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
                                                .fill(viewModel.editingProfileEmoji == emoji ? Color.blue.opacity(0.2) : Color.clear)
                                        )
                                        .overlay(
                                            Circle()
                                                .strokeBorder(viewModel.editingProfileEmoji == emoji ? Color.blue : Color.clear, lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Avatar Color Picker
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Avatar Color")
                            .font(.headline)
                            .padding(.horizontal)

                        HStack(spacing: 12) {
                            ForEach(0..<PoolUserProfile.availableColors.count, id: \.self) { index in
                                Button {
                                    viewModel.editingProfileColorIndex = index
                                } label: {
                                    Circle()
                                        .fill(PoolUserProfile.availableColors[index])
                                        .frame(width: 36, height: 36)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.white, lineWidth: viewModel.editingProfileColorIndex == index ? 3 : 0)
                                        )
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.primary.opacity(0.3), lineWidth: viewModel.editingProfileColorIndex == index ? 1 : 0)
                                        )
                                        .shadow(color: viewModel.editingProfileColorIndex == index ? PoolUserProfile.availableColors[index].opacity(0.5) : Color.clear, radius: 4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }

                    // Info text
                    Text("Your profile will be visible to other pool members in chat and games.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Spacer(minLength: 40)
                }
            }
            .navigationTitle("Edit Profile")
            .crossPlatformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelProfileEditing()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
    @Environment(\.dismiss) private var dismiss
    @State private var serverURLInput: String = ""
    var body: some View {
        NavigationView {
            Group {
                if viewModel.showClaimCodeInput {
                    RemoteHostClaimView(viewModel: viewModel, dismiss: dismiss)
                } else {
                    ScrollView {
                        VStack(spacing: 24) {
                            // Header
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.purple.opacity(0.15))
                                        .frame(width: 80, height: 80)

                                    Image(systemName: "server.rack")
                                        .font(.system(size: 36))
                                        .foregroundStyle(.purple)
                                }

                                Text("Host Remote Pool")
                                    .font(.title2.bold())

                                Text("Create a pool that anyone can join\nvia invitation link, from anywhere.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top)

                            // Server URL
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Server URL")
                                    .font(.headline)

                                TextField("10.0.0.4:9090 or relay.example.com", text: $serverURLInput)
                                    .textFieldStyle(.roundedBorder)
                                    .autocorrectionDisabled()
                                    .crossPlatformTextField()

                                Text("IP:port for local, domain for internet (via cloudflared)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            // Pool Name
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Pool Name")
                                    .font(.headline)

                                TextField("Enter pool name", text: $viewModel.poolName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            // Max Members
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Max Members")
                                    .font(.headline)

                                Picker("Max Members", selection: $viewModel.maxPeers) {
                                    ForEach([2, 4, 6, 8, 10, 12, 16], id: \.self) { count in
                                        Text("\(count) members").tag(count)
                                    }
                                }
                                .pickerStyle(.segmented)

                                Text("Maximum number of peers that can join this pool")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 20)

                            // Create Button
                            Button {
                                viewModel.createRemotePool(serverURL: serverURLInput)
                            } label: {
                                HStack {
                                    if viewModel.isConnectingRemote {
                                        ProgressView()
                                            .tint(.white)
                                    } else {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                    }
                                    Text(viewModel.isConnectingRemote ? "Connecting..." : "Create Remote Pool")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(serverURLInput.isEmpty || viewModel.isConnectingRemote ? Color.gray : Color.purple)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .disabled(serverURLInput.isEmpty || viewModel.isConnectingRemote)
                        }
                        .padding()
                    }
                    .navigationTitle("")
                    .crossPlatformInlineNavigationTitle()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
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
    let dismiss: DismissAction
    @State private var showQRScanner: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 50))
                        .foregroundStyle(.orange)

                    Text("Server Claim Required")
                        .font(.title2.bold())

                    Text("Scan the QR code or enter the claim code\nfrom your server's Docker logs.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top)

                // QR Scanner Button
                #if os(iOS)
                Button {
                    showQRScanner = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 24))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan QR Code")
                                .font(.headline)
                            Text("Point camera at your server's terminal")
                                .font(.caption)
                                .foregroundStyle(.orange.opacity(0.8))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.orange.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
                .background(Color.orange.opacity(0.12))
                .foregroundStyle(.orange)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                #endif

                // Divider
                HStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("or enter manually")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.horizontal)

                // Manual Entry
                VStack(spacing: 16) {
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
                            HStack {
                                Image(systemName: "key.fill")
                                Text("Claim Server")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                    }
                    .background(viewModel.claimCode.isEmpty || viewModel.isClaimingServer ? Color.gray : Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(viewModel.claimCode.isEmpty || viewModel.isClaimingServer)
                }
                .padding(.horizontal)

                // Server claimed confirmation
                if viewModel.serverClaimed {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Server claimed successfully")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle("Claim Server")
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

    private var hasSaved: Bool {
        hasCopied || viewModel.recoveryKeySavedToPasswordManager
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "key.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)

                Text("Save Your Recovery Key")
                    .font(.title2.bold())

                Text("This key is the only way to reclaim your server if the binding is lost. It will not be shown again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if let key = viewModel.serverRecoveryKey {
                    Text(key)
                        .font(.system(.caption, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
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
                            HStack {
                                if isSavingToPasswordManager {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: viewModel.recoveryKeySavedToPasswordManager
                                          ? "checkmark.shield.fill" : "lock.shield")
                                    Text(viewModel.recoveryKeySavedToPasswordManager
                                         ? "Saved to Password Manager" : "Save to Password Manager")
                                }
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .background(viewModel.recoveryKeySavedToPasswordManager
                                    ? Color.green : Color.orange)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                        HStack {
                            Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                            Text(hasCopied ? "Copied" : "Copy to Clipboard")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                Spacer()

                Button {
                    viewModel.acknowledgeRecoveryKey()
                } label: {
                    Text("I've Saved My Recovery Key")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .background(hasSaved ? Color.orange : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(!hasSaved)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .padding(.top, 30)
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
    @State private var pendingForget: RemoteMemberRecord?

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Your Pools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            "Forget this pool?",
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            presenting: pendingForget
        ) { record in
            Button("Forget", role: .destructive) {
                viewModel.forgetRemoteMemberPool(record)
                pendingForget = nil
            }
            Button("Cancel", role: .cancel) {
                pendingForget = nil
            }
        } message: { _ in
            Text("You'll need a new invitation to join again.")
        }
    }
}

private struct SavedMemberPoolRow: View {
    let record: RemoteMemberRecord
    let onRejoin: () -> Void
    let onForget: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onRejoin) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName.isEmpty ? "Remote Pool" : record.displayName)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(record.serverURL)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let last = record.lastSuccessfulConnectAt {
                            Text("Last connected \(last, style: .relative) ago")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onForget) {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Invitation Share Sheet (replaced by InviteCardShareSheet)
// The PIN-driven invite-card flow lives in InviteCardShareSheet.swift.

// MARK: - Remote Invitations Card

private struct RemoteInvitationsCard: View {
    @ObservedObject var viewModel: ConnectionPoolViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "link")
                    .foregroundStyle(.purple)
                Text("Active Invitations")
                    .font(.subheadline.bold())

                Spacer()

                Text("\(viewModel.remoteInvitations.filter { !$0.isExpired }.count)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple)
                    .clipShape(Capsule())
            }

            ForEach(viewModel.remoteInvitations) { invitation in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invitation.tokenId.prefix(8) + "...")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)

                        if invitation.isExpired {
                            Text("Expired")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        } else {
                            Text("Expires \(invitation.expiresAt, style: .relative)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if !invitation.isExpired {
                        Button {
                            viewModel.shareInvitation(invitation)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline)
                                .foregroundStyle(.purple)
                                .padding(8)
                                .background(Color.purple.opacity(0.1))
                                .clipShape(Circle())
                        }
                    }

                    Button {
                        viewModel.remoteInvitations.removeAll { $0.id == invitation.id }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
        .background(Color.purple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
