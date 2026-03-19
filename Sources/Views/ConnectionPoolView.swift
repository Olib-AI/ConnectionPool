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

    var body: some View {
        VStack(spacing: 24) {
            // Profile button in top right
            HStack {
                Spacer()
                ProfileButton(viewModel: viewModel)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

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

                Text("Connect with nearby devices\nfor chat and games")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

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

            // Info Section
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    InfoBadge(icon: "lock.fill", text: "Encrypted")
                    InfoBadge(icon: "wifi.slash", text: "No Internet")
                    InfoBadge(icon: "person.3.fill", text: "Up to 8")
                }
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding()
        .crossPlatformNavigationBarHidden(true)
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

                        // Pending Invitations (for host)
                        if viewModel.isHost && !viewModel.pendingInvitations.isEmpty {
                            PendingInvitationsCard(viewModel: viewModel)
                        }

                        // Participants
                        ParticipantsCard(viewModel: viewModel)

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

// MARK: - Connection Status Card

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
    let onKick: () -> Void
    let onBlock: () -> Void

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
                    Image(systemName: peer.status.iconName)
                        .font(.caption2)
                    Text(peer.status.displayText)
                        .font(.caption)
                }
                .foregroundStyle(peer.status == .connected ? .green : .secondary)
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
            // Invite button (for host)
            if viewModel.isHost {
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

            // Disconnect Button
            Button {
                viewModel.disconnect()
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
        }
        .sheet(isPresented: $showGamesSheet) {
            GamesSelectionSheet(viewModel: viewModel)
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
