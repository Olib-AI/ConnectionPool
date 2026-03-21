// ConnectionPoolViewModel.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine

/// View model for the Connection Pool app
@MainActor
public final class ConnectionPoolViewModel: ObservableObject, PoolAppLifecycle {

    // MARK: - Published Properties

    /// Current view state
    @Published public var currentView: ConnectionPoolViewState = .home

    /// Pool configuration for hosting
    @Published public var poolName: String = ""
    @Published public var maxPeers: Int = 8
    @Published public var requireEncryption: Bool = true
    @Published public var autoAcceptPeers: Bool = false

    /// User profile settings
    @Published public var showProfileSettings: Bool = false
    @Published public var editingProfileName: String = ""
    @Published public var editingProfileEmoji: String = ""
    @Published public var editingProfileColorIndex: Int = 0

    /// Chat messages (kept for backward compatibility)
    @Published public var chatMessages: [ChatMessage] = []
    @Published public var chatInput: String = ""

    /// Pending invitations list (for host)
    @Published public var pendingInvitations: [DiscoveredPeer] = []

    /// Current invitation being shown in sheet
    @Published public var currentInvitation: DiscoveredPeer?
    @Published public var showInvitationSheet: Bool = false

    /// Pool join code entry - uses ZStack overlay approach for reliability
    /// The overlay is shown when both showJoinCodeOverlay is true AND pendingJoinPeer is set
    @Published public var showJoinCodeOverlay: Bool = false
    @Published public var joinCodeInput: String = ""
    @Published public var pendingJoinPeer: DiscoveredPeer?

    /// Blocked devices
    @Published public var blockedDevices: [BlockedDevice] = []
    @Published public var showBlockedDevicesSheet: Bool = false

    /// Server claim state
    @Published public var claimCode: String = ""
    @Published public var showClaimCodeInput: Bool = false
    @Published public var isClaimingServer: Bool = false
    @Published public var serverClaimed: Bool = false

    /// Remote pool state
    @Published public var transportMode: TransportMode = .local
    @Published public var serverURL: String = ""
    @Published public var remoteInvitations: [RemoteInvitation] = []
    @Published public var showInvitationShareSheet: Bool = false
    @Published public var currentRemoteInvitation: RemoteInvitation?
    @Published public var showRemoteJoinSheet: Bool = false
    @Published public var invitationURLInput: String = ""
    @Published public var isConnectingRemote: Bool = false

    /// Error handling
    @Published public var errorMessage: String?
    @Published public var showError: Bool = false

    /// Callback for opening Pool Chat app
    public var onOpenPoolChat: (() -> Void)?

    /// Callback for opening a game
    public var onOpenGame: ((MultiplayerGameType) -> Void)?

    // MARK: - Remote Pool Service

    /// Service for managing remote host identity, invitations, and QR codes.
    public let remotePoolService = RemotePoolService()

    // MARK: - Connection Pool Manager

    /// Uses the shared singleton to ensure connection survives window close/reopen cycles
    public let poolManager = ConnectionPoolManager.shared

    // MARK: - Observed Pool Manager State
    // These mirror poolManager's published properties to ensure SwiftUI observes changes
    // SwiftUI does not automatically observe nested @ObservableObject @Published properties

    @Published public private(set) var poolState: PoolState = .idle
    @Published public private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published public private(set) var connectedPeers: [Peer] = []
    @Published public private(set) var currentSession: PoolSession?
    @Published public private(set) var isHost: Bool = false

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    /// Peer IDs (relay-authenticated public keys) that were approved during this session.
    /// Used to auto-accept reconnecting peers without re-prompting the host.
    private var approvedPeerIDs: Set<String> = []

    /// WebSocket transport reference for remote mode.
    private var webSocketTransport: WebSocketTransport?

    /// Pool ID for the current remote hosting session (used to retry HostAuth after claim).
    private var remotePoolID: UUID?

    // MARK: - PoolAppLifecycle

    @Published public private(set) var runtimeState: PoolAppState = .active

    // MARK: - Initialization

    public init() {
        setupSubscriptions()
        setupDefaultPoolName()
        initializeProfileEditing()

        // Share pool manager with MultiplayerGameService singleton
        // This ensures games can detect pool connection and send multiplayer messages
        MultiplayerGameService.shared.setPoolManager(poolManager)

        // Sync initial state from the shared pool manager (in case connection was established before)
        syncInitialStateFromPoolManager()

        // Auto-reconnect to saved remote pool if available
        restoreSavedRemotePool()
    }

    /// Sync the ViewModel's published state with the shared pool manager's current state
    /// This handles the case where the window was closed and reopened while connected
    private func syncInitialStateFromPoolManager() {
        poolState = poolManager.poolState
        discoveredPeers = poolManager.discoveredPeers
        connectedPeers = poolManager.connectedPeers
        currentSession = poolManager.currentSession
        isHost = poolManager.isHost
        blockedDevices = poolManager.blockedDevices

        // Set the view to lobby if already connected
        if poolState == .hosting || poolState == .connected {
            currentView = .lobby
        }
    }

    /// Restore a previously saved remote pool and auto-reconnect.
    private func restoreSavedRemotePool() {
        guard let saved = RemotePoolState.load() else { return }

        // Only auto-reconnect if we were the host and the server was claimed
        guard saved.isHost, saved.isClaimed else { return }

        log("Restoring remote pool: \(saved.serverURL)", category: .network)

        guard let url = URL(string: saved.serverURL) else { return }

        let config = RemotePoolConfiguration(
            serverURL: url,
            poolName: saved.poolName,
            maxPeers: saved.maxPeers
        )

        transportMode = .remote
        serverURL = saved.serverURL
        poolName = saved.poolName
        maxPeers = saved.maxPeers

        let transport = WebSocketTransport(
            configuration: config,
            displayName: poolManager.localProfile.displayName
        )
        transport.delegate = self
        webSocketTransport = transport

        remotePoolID = saved.poolID
        do {
            let identity = try remotePoolService.getOrCreateHostIdentity()
            let poolInfo = PoolAdvertisementInfo(
                poolID: saved.poolID,
                poolName: saved.poolName,
                hostName: poolManager.localProfile.displayName,
                hasPoolCode: false,
                maxPeers: saved.maxPeers,
                hostProfile: poolManager.localProfile
            )
            transport.startAdvertising(poolInfo: poolInfo)
            isHost = true
            poolState = .connecting
            isConnectingRemote = true
            _ = identity
        } catch {
            log("Failed to restore remote pool: \(error)", category: .network)
            transportMode = .local
            webSocketTransport = nil
            RemotePoolState.clear()
        }
    }

    private func setupDefaultPoolName() {
        poolName = "\(poolManager.localProfile.displayName)'s Pool"
    }

    private func initializeProfileEditing() {
        let profile = poolManager.localProfile
        editingProfileName = profile.displayName
        editingProfileEmoji = profile.avatarEmoji
        editingProfileColorIndex = profile.avatarColorIndex
    }

    /// Current user profile
    public var localProfile: PoolUserProfile {
        poolManager.localProfile
    }

    /// Start editing profile
    public func startEditingProfile() {
        editingProfileName = poolManager.localProfile.displayName
        editingProfileEmoji = poolManager.localProfile.avatarEmoji
        editingProfileColorIndex = poolManager.localProfile.avatarColorIndex
        showProfileSettings = true
    }

    /// Save profile changes
    public func saveProfile() {
        let name = editingProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showError(message: "Display name cannot be empty")
            return
        }

        let profile = PoolUserProfile(
            displayName: name,
            avatarEmoji: editingProfileEmoji,
            avatarColorIndex: editingProfileColorIndex
        )
        poolManager.updateProfile(profile)

        // Update pool name if it was using the default
        if poolName.hasSuffix("'s Pool") {
            poolName = "\(name)'s Pool"
        }

        showProfileSettings = false
    }

    /// Cancel profile editing
    public func cancelProfileEditing() {
        initializeProfileEditing()
        showProfileSettings = false
    }

    private func setupSubscriptions() {
        // Subscribe to pool state changes and mirror to our published property
        poolManager.$poolState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.poolState = state
                self?.handlePoolStateChange(state)
            }
            .store(in: &cancellables)

        // Subscribe to discovered peers and mirror to our published property
        poolManager.$discoveredPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.discoveredPeers = peers
            }
            .store(in: &cancellables)

        // Subscribe to connected peers and mirror to our published property
        poolManager.$connectedPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.connectedPeers = peers
            }
            .store(in: &cancellables)

        // Subscribe to current session and mirror to our published property
        poolManager.$currentSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.currentSession = session
            }
            .store(in: &cancellables)

        // Subscribe to isHost and mirror to our published property
        poolManager.$isHost
            .receive(on: DispatchQueue.main)
            .sink { [weak self] host in
                self?.isHost = host
            }
            .store(in: &cancellables)

        // Subscribe to received messages
        poolManager.messageReceived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleReceivedMessage(message)
            }
            .store(in: &cancellables)

        // Subscribe to peer events
        poolManager.peerEvent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handlePeerEvent(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - PoolAppLifecycle Protocol

    public func activate() {
        runtimeState = .active
        log("ConnectionPool activated", category: .runtime)
    }

    public func moveToBackground() {
        runtimeState = .background
        log("ConnectionPool moved to background", category: .runtime)
    }

    public func suspend() {
        // Don't suspend if there's an active connection - the pool should keep running
        // to maintain connectivity with peers. This prevents the connection from being
        // disrupted when the user switches to another app window.
        let currentPoolState = poolManager.poolState
        if currentPoolState == .connected || currentPoolState == .hosting {
            log("ConnectionPool suspend skipped - active connection (\(currentPoolState))", category: .runtime)
            // Keep state as background instead of suspended to allow continued operation
            runtimeState = .background
            return
        }

        runtimeState = .suspended
        log("ConnectionPool suspended", category: .runtime)
    }

    public func terminate() {
        runtimeState = .terminated
        // NOTE: We intentionally do NOT disconnect when the window closes.
        // The pool connection should persist until the user explicitly disconnects
        // via the "Close Pool" / "Leave Pool" button, or the app is fully terminated.
        // poolManager.disconnect() is NOT called here.
        cancellables.removeAll()
        log("ConnectionPool terminated (connection kept alive)", category: .runtime)
    }

    /// Explicitly disconnect from the pool. Call this when user wants to leave.
    public func explicitDisconnect() {
        if transportMode == .remote {
            webSocketTransport?.disconnect()
            webSocketTransport = nil
            poolManager.remoteTransport = nil
            poolManager.remotePeerID = nil
            poolManager.setRemotePoolState(poolState: .idle, session: nil, isHost: false)
        }
        poolManager.disconnect()
        transportMode = .local
        serverURL = ""
        remoteInvitations = []
        showInvitationShareSheet = false
        currentRemoteInvitation = nil
        showRemoteJoinSheet = false
        invitationURLInput = ""
        isConnectingRemote = false
        resetClaimState()
        RemotePoolState.clear()
        currentView = .home
        chatMessages = []
        pendingInvitations = []
        log("ConnectionPool explicitly disconnected by user", category: .runtime)
    }

    // MARK: - Public Actions

    /// Start hosting a new pool
    public func startHosting() {
        guard !poolName.isEmpty else {
            showError(message: "Please enter a pool name")
            return
        }

        let config = PoolConfiguration(
            name: poolName,
            maxPeers: maxPeers,
            requireEncryption: requireEncryption,
            autoAcceptInvitations: autoAcceptPeers,
            generatePoolCode: true
        )

        poolManager.startHosting(configuration: config)
        currentView = .lobby
    }

    /// Start browsing for pools
    public func startBrowsing() {
        poolManager.startBrowsing()
        currentView = .browse
    }

    /// Refresh browsing (restart scanning)
    public func refreshBrowsing() {
        poolManager.disconnect()
        poolManager.startBrowsing()
    }

    /// Join a discovered pool
    public func joinPool(_ peer: DiscoveredPeer) {
        log("joinPool called for peer: \(peer.displayName), hasCode: \(peer.hasPoolCode)", category: .network)

        // If the pool requires a code, prompt the user to enter it via overlay
        if peer.hasPoolCode {
            log("Pool requires code, showing code entry overlay", category: .network)
            pendingJoinPeer = peer
            joinCodeInput = ""
            showJoinCodeOverlay = true
        } else {
            // No code required, join directly
            log("No code required, joining directly", category: .network)
            poolManager.joinPool(peer)
        }
    }

    /// Confirm joining with the entered code.
    /// The code is sent to the host via MC invitation context for server-side validation.
    public func confirmJoinWithCode() {
        guard let peer = pendingJoinPeer else { return }

        let enteredCode = joinCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard !enteredCode.isEmpty else {
            showError(message: "Please enter a pool code.")
            return
        }

        // SECURITY: Do NOT validate client-side. Send to host for authoritative validation.
        // The host will reject the MC invitation if the code is wrong.
        showJoinCodeOverlay = false
        let peerToJoin = peer
        pendingJoinPeer = nil
        joinCodeInput = ""
        poolManager.joinPool(peerToJoin, poolCode: enteredCode)
    }

    /// Cancel joining a pool
    public func cancelJoin() {
        showJoinCodeOverlay = false
        pendingJoinPeer = nil
        joinCodeInput = ""
    }

    /// Send a chat message
    public func sendChatMessage() {
        guard !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        poolManager.sendChat(chatInput)
        chatInput = ""
    }

    /// Disconnect from the current pool (user-initiated)
    public func disconnect() {
        if transportMode == .remote {
            webSocketTransport?.disconnect()
            webSocketTransport = nil
        }
        poolManager.disconnect()

        // Dismiss any open sheets first to avoid SwiftUI presentation conflicts
        showInvitationShareSheet = false
        showInvitationSheet = false
        showRemoteJoinSheet = false
        showClaimCodeInput = false
        currentInvitation = nil
        currentRemoteInvitation = nil

        // Defer the full state reset to the next run loop tick so sheet
        // dismissal animations complete before the view hierarchy changes.
        // This prevents SwiftUI's sheet presentation state from getting
        // corrupted by simultaneous view updates.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }

            self.currentView = .home
            self.chatMessages = []
            self.pendingInvitations = []
            self.approvedPeerIDs.removeAll()
            self.transportMode = .local
            self.isConnectingRemote = false
            self.isHost = false
            self.poolState = .idle
            self.connectedPeers = []
            self.currentSession = nil
            self.remoteInvitations = []
            self.isClaimingServer = false
            self.claimCode = ""
            self.invitationURLInput = ""
            self.remotePoolID = nil
        }

        log("ConnectionPool disconnected by user action", category: .runtime)
    }

    /// Accept an invitation
    public func acceptInvitation(_ invitation: DiscoveredPeer) {
        // Track this peer's ID so reconnections are auto-accepted
        approvedPeerIDs.insert(invitation.id)

        if transportMode == .remote, let transport = webSocketTransport {
            transport.acceptConnection(from: invitation.id)

            // Remove single-use invitations once a peer joins through them.
            // For multi-use invitations, keep them but remove expired ones.
            remoteInvitations.removeAll { invite in
                invite.isExpired || (invite.maxUses == 1)
            }
        } else {
            poolManager.acceptInvitation(from: invitation.id)
        }
        pendingInvitations.removeAll { $0.id == invitation.id }

        if currentInvitation?.id == invitation.id {
            currentInvitation = nil
            showInvitationSheet = false
        }
    }

    /// Reject an invitation
    public func rejectInvitation(_ invitation: DiscoveredPeer) {
        if transportMode == .remote, let transport = webSocketTransport {
            transport.rejectConnection(from: invitation.id)
        } else {
            poolManager.rejectInvitation(from: invitation.id)
        }
        pendingInvitations.removeAll { $0.id == invitation.id }

        if currentInvitation?.id == invitation.id {
            currentInvitation = nil
            showInvitationSheet = false
        }
    }

    /// Accept pending invitation (backward compatibility)
    public func acceptPendingInvitation() {
        guard let invitation = currentInvitation else { return }
        acceptInvitation(invitation)
    }

    /// Reject pending invitation (backward compatibility)
    public func rejectPendingInvitation() {
        guard let invitation = currentInvitation else { return }
        rejectInvitation(invitation)
    }

    /// Kick a peer from the pool (host only)
    public func kickPeer(_ peer: Peer) {
        // TODO: Implement kick functionality in ConnectionPoolManager
        log("Kicking peer: \(peer.displayName)", category: .network)
    }

    /// Block a connected peer (host only) - also kicks them
    public func blockPeer(_ peer: Peer) {
        poolManager.blockDevice(peer.id, displayName: peer.effectiveDisplayName)
        refreshBlockedDevices()
    }

    /// Block a peer from pending invitations (host only) - also rejects the invitation
    public func blockPendingPeer(_ invitation: DiscoveredPeer) {
        poolManager.blockDevice(invitation.id, displayName: invitation.displayName)
        pendingInvitations.removeAll { $0.id == invitation.id }
        if currentInvitation?.id == invitation.id {
            currentInvitation = nil
            showInvitationSheet = false
        }
        refreshBlockedDevices()
    }

    /// Unblock a device
    public func unblockDevice(_ device: BlockedDevice) {
        poolManager.unblockDevice(device.id)
        refreshBlockedDevices()
    }

    /// Refresh the blocked devices list from the manager
    private func refreshBlockedDevices() {
        blockedDevices = poolManager.blockedDevices
    }

    /// Open Pool Chat app
    public func openPoolChat() {
        onOpenPoolChat?()
    }

    /// Open a multiplayer game
    public func openGame(_ gameType: MultiplayerGameType) {
        onOpenGame?(gameType)
    }

    // MARK: - Remote Pool Actions

    /// Create a remote pool on the specified server.
    public func createRemotePool(serverURL serverURLString: String) {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError(message: "Please enter a server URL")
            return
        }

        // Normalize the URL: add ws:// scheme if missing.
        // Use ws:// for local/IP connections, wss:// for domain names.
        let normalized: String
        if trimmed.hasPrefix("wss://") || trimmed.hasPrefix("ws://") {
            normalized = trimmed
        } else if trimmed.contains(".") && !trimmed.contains(":") {
            // Looks like a domain name without port — use wss://
            normalized = "wss://\(trimmed)"
        } else {
            // IP address or IP:port — use plain ws://
            normalized = "ws://\(trimmed)"
        }

        guard let url = URL(string: normalized) else {
            showError(message: "Invalid server URL")
            return
        }

        let name = poolName.isEmpty ? "\(poolManager.localProfile.displayName)'s Pool" : poolName
        let config = RemotePoolConfiguration(
            serverURL: url,
            poolName: name,
            maxPeers: maxPeers
        )

        transportMode = .remote
        serverURL = normalized

        let transport = WebSocketTransport(
            configuration: config,
            displayName: poolManager.localProfile.displayName
        )
        transport.delegate = self
        webSocketTransport = transport

        let poolID = UUID()
        remotePoolID = poolID
        do {
            let identity = try remotePoolService.getOrCreateHostIdentity()
            let poolInfo = PoolAdvertisementInfo(
                poolID: poolID,
                poolName: name,
                hostName: poolManager.localProfile.displayName,
                hasPoolCode: false,
                maxPeers: maxPeers,
                hostProfile: poolManager.localProfile
            )
            transport.startAdvertising(poolInfo: poolInfo)
            isHost = true
            poolState = .connecting
            isConnectingRemote = true
            // Don't navigate to lobby yet — wait for HostAuthSuccess or error via delegate.
            // The delegate's didChangeState(.advertising) will set poolState = .hosting
            // and navigate to .lobby when the server confirms.
            log("Connecting to remote server \(normalized)...", category: .network)
            _ = identity
        } catch {
            showError(message: "Failed to create host identity: \(error.localizedDescription)")
            transportMode = .local
            webSocketTransport = nil
        }
    }

    /// Submit the claim code to bind this device as the server's host.
    ///
    /// After a successful claim, the server remembers the bound host identity
    /// and future connections proceed with normal HostAuth without re-claiming.
    public func submitClaimCode() {
        guard let transport = webSocketTransport else { return }
        let code = claimCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            showError(message: "Please enter a claim code")
            return
        }
        isClaimingServer = true
        transport.claimServer(claimCode: code)
    }

    /// Handle a scanned QR code or deep link string for server claiming.
    ///
    /// Accepts any format supported by `WebSocketTransport.normalizeClaimCode`:
    /// - `stealth://claim/<hex>` URL
    /// - Dash-separated hex
    /// - Raw hex string
    ///
    /// When a transport is already connected and waiting for a claim, this
    /// automatically populates the claim code and submits it.
    public func handleClaimDeepLink(_ rawValue: String) {
        let normalized = WebSocketTransport.normalizeClaimCode(rawValue)
        guard !normalized.isEmpty else {
            showError(message: "Invalid claim QR code")
            return
        }
        claimCode = normalized
        // If we already have a transport connected and waiting for claim, submit automatically
        if showClaimCodeInput, webSocketTransport != nil {
            submitClaimCode()
        }
    }

    /// Reset claim-related state when leaving the remote host flow.
    private func resetClaimState() {
        claimCode = ""
        showClaimCodeInput = false
        isClaimingServer = false
        serverClaimed = false
    }

    /// Join a remote pool via invitation URL.
    public func joinRemotePool(invitationURL: String) {
        let trimmed = invitationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError(message: "Please enter an invitation URL")
            return
        }

        guard let url = URL(string: trimmed) else {
            showError(message: "Invalid invitation URL")
            return
        }

        guard let invitation = RemotePoolService.parseInvitationURL(url) else {
            showError(message: "Could not parse invitation. Make sure the link is valid and not expired.")
            return
        }

        if invitation.isExpired {
            showError(message: "This invitation has expired.")
            return
        }

        let config = RemotePoolConfiguration(
            serverURL: invitation.serverURL,
            poolName: "Remote Pool",
            maxPeers: 8
        )

        transportMode = .remote
        serverURL = invitation.serverURL.absoluteString
        isConnectingRemote = true

        let transport = WebSocketTransport(
            configuration: config,
            displayName: poolManager.localProfile.displayName
        )
        transport.delegate = self
        webSocketTransport = transport

        transport.requestJoinWithInvitation(invitation)
        log("Joining remote pool via invitation", category: .network)
    }

    /// Generate a new invitation (remote mode, any connected member).
    /// The host always approves join requests regardless of who created the invite.
    public func createRemoteInvitation(maxUses: Int = 1, expiresInSecs: UInt64 = 300) {
        guard transportMode == .remote else {
            showError(message: "Invitations are only available in remote mode")
            return
        }
        guard let transport = webSocketTransport else {
            showError(message: "Not connected to remote server")
            return
        }
        // Only the host can create invitations — the relay server requires the
        // host's session token for CreateInvitation. Guests can share existing
        // invitation URLs but cannot mint new ones.
        guard isHost else {
            // If we have an existing invitation from the host, share that instead
            if let existing = remoteInvitations.first(where: { !$0.isExpired }) {
                shareInvitation(existing)
            } else {
                showError(message: "Only the pool host can create new invitations.")
            }
            return
        }

        Task { @MainActor in
            let invitation = await remotePoolService.createInvitation(
                transport: transport,
                maxUses: maxUses,
                expiresInSecs: expiresInSecs
            )
            if let invitation {
                remoteInvitations.append(invitation)
                currentRemoteInvitation = invitation
                showInvitationShareSheet = true
                log("Created remote invitation (tokenId: \(invitation.tokenId.prefix(8))..., expires: \(invitation.expiresAt))", category: .network)
            } else {
                showError(message: "Failed to create invitation. Please try again.")
            }
        }
    }

    /// Share an existing invitation URL/QR.
    public func shareInvitation(_ invitation: RemoteInvitation) {
        currentRemoteInvitation = invitation
        showInvitationShareSheet = true
    }

    /// Any connected member can generate an invite link.
    /// The host still approves all joins.
    public func requestInviteLink(maxUses: Int = 1, expiresInSecs: UInt64 = 300) {
        createRemoteInvitation(maxUses: maxUses, expiresInSecs: expiresInSecs)
    }

    /// Go back to home view
    public func goBack() {
        switch currentView {
        case .browse:
            poolManager.disconnect()
            currentView = .home
        case .lobby:
            if transportMode == .remote {
                // In remote mode, leaving the lobby means disconnecting
                disconnect()
            } else if poolManager.poolState == .idle {
                // Not yet hosting, just go back
                currentView = .home
            } else {
                // Hosting or connected, disconnect
                disconnect()
            }
        case .chat:
            currentView = .lobby
        default:
            currentView = .home
        }
    }

    // MARK: - Private Handlers

    private func handlePoolStateChange(_ state: PoolState) {
        switch state {
        case .connected:
            currentView = .lobby
        case .error(let message):
            showError(message: message)
        default:
            break
        }
    }

    private func handleReceivedMessage(_ message: PoolMessage) {
        switch message.type {
        case .chat:
            if let payload = message.decodePayload(as: ChatPayload.self) {
                let chatMessage = ChatMessage(
                    id: message.id,
                    senderID: message.senderID,
                    senderName: message.senderName,
                    text: payload.text,
                    timestamp: message.timestamp,
                    isFromLocalUser: message.senderID == poolManager.localPeerID
                )
                if !chatMessages.contains(where: { $0.id == chatMessage.id }) {
                    chatMessages.append(chatMessage)
                }
            }

        case .system:
            if let payload = message.decodePayload(as: SystemPayload.self) {
                let systemMessage = ChatMessage(
                    id: message.id,
                    senderID: "system",
                    senderName: "System",
                    text: payload.text,
                    timestamp: message.timestamp,
                    isFromLocalUser: false,
                    isSystemMessage: true
                )
                if !chatMessages.contains(where: { $0.id == systemMessage.id }) {
                    chatMessages.append(systemMessage)
                }
            }

        case .profileUpdate:
            if let payload = message.decodePayload(as: ProfileUpdatePayload.self) {
                poolManager.updatePeerProfile(peerID: payload.peerID, profile: payload.profile)
            }

        default:
            // Handle other message types (game states, etc.)
            break
        }
    }

    private func handlePeerEvent(_ event: PeerEvent) {
        switch event {
        case .connected(let peer):
            let systemMessage = ChatMessage(
                senderID: "system",
                senderName: "System",
                text: "\(peer.displayName) joined the pool",
                isFromLocalUser: false,
                isSystemMessage: true
            )
            if !chatMessages.contains(where: { $0.id == systemMessage.id }) {
                chatMessages.append(systemMessage)
            }

        case .disconnected(let peer):
            let systemMessage = ChatMessage(
                senderID: "system",
                senderName: "System",
                text: "\(peer.displayName) left the pool",
                isFromLocalUser: false,
                isSystemMessage: true
            )
            if !chatMessages.contains(where: { $0.id == systemMessage.id }) {
                chatMessages.append(systemMessage)
            }

        case .invitationReceived(let peer):
            // Add to pending invitations list
            if !pendingInvitations.contains(where: { $0.id == peer.id }) {
                pendingInvitations.append(peer)
            }

            // If auto-accept is disabled and we're not showing a sheet, show it
            if !autoAcceptPeers && currentInvitation == nil {
                currentInvitation = peer
                showInvitationSheet = true
            }

        case .invitationRejectedBlocked(let name):
            log("Rejected invitation from blocked device: \(name)", category: .network)

        case .deviceAutoBlocked(let name):
            refreshBlockedDevices()
            log("Device auto-blocked after repeated failed attempts: \(name)", category: .network)
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - TransportDelegate Conformance (Remote Mode)

extension ConnectionPoolViewModel: TransportDelegate {

    public func transport(_ transport: any TransportProvider, didChangeState state: TransportState) {
        switch state {
        case .connected:
            isConnectingRemote = false
            poolState = .connected
            currentView = .lobby
            // Bridge for joiner
            if transportMode == .remote, let ws = webSocketTransport {
                poolManager.remoteTransport = ws
                poolManager.remotePeerID = ws.localPeerID
                let session = PoolSession(
                    name: poolName.isEmpty ? "Remote Pool" : poolName,
                    hostPeerID: "host",
                    maxPeers: maxPeers
                )
                poolManager.setRemotePoolState(poolState: .connected, session: session, isHost: false)

                // Add self as a participant
                let selfPeer = Peer(
                    id: ws.localPeerID,
                    displayName: poolManager.localProfile.displayName,
                    isHost: false,
                    status: .connected,
                    profile: poolManager.localProfile
                )
                if !connectedPeers.contains(where: { $0.id == selfPeer.id }) {
                    connectedPeers.insert(selfPeer, at: 0)
                }
                poolManager.addRemotePeer(selfPeer)
            }
        case .advertising:
            isConnectingRemote = false
            poolState = .hosting
            currentView = .lobby
            // Bridge remote state into ConnectionPoolManager so games/chat detect the pool
            if transportMode == .remote, let ws = webSocketTransport, let poolID = remotePoolID {
                poolManager.remoteTransport = ws
                poolManager.remotePeerID = ws.localPeerID
                let session = PoolSession(
                    name: poolName,
                    hostPeerID: poolManager.localPeerID,
                    maxPeers: maxPeers
                )
                poolManager.setRemotePoolState(poolState: .hosting, session: session, isHost: true)

                // Add the host as the first participant
                let hostPeer = Peer(
                    id: poolManager.localPeerID,
                    displayName: poolManager.localProfile.displayName,
                    isHost: true,
                    status: .connected,
                    profile: poolManager.localProfile
                )
                if !connectedPeers.contains(where: { $0.id == hostPeer.id }) {
                    connectedPeers.insert(hostPeer, at: 0)
                }
                poolManager.addRemotePeer(hostPeer)
            }
            // Save remote pool state so it persists across app restarts
            if transportMode == .remote, let poolID = remotePoolID {
                let state = RemotePoolState(
                    serverURL: serverURL,
                    poolName: poolName,
                    isClaimed: true,
                    poolID: poolID,
                    maxPeers: maxPeers,
                    isHost: true
                )
                state.save()
                log("Remote pool state saved", category: .network)
            }
        case .connecting:
            poolState = .connecting
        case .failed(let error):
            isConnectingRemote = false
            showError(message: error.localizedDescription)
            poolState = .error(error.localizedDescription)
        case .reconnecting:
            break
        case .idle:
            // After a successful claim, the transport signals .idle so we can proceed to HostAuth.
            if isClaimingServer {
                isClaimingServer = false
                serverClaimed = true
                showClaimCodeInput = false

                // Automatically proceed with HostAuth on the existing connection.
                if let wsTransport = webSocketTransport, let poolID = remotePoolID {
                    let name = poolName.isEmpty ? "\(poolManager.localProfile.displayName)'s Pool" : poolName
                    let poolInfo = PoolAdvertisementInfo(
                        poolID: poolID,
                        poolName: name,
                        hostName: poolManager.localProfile.displayName,
                        hasPoolCode: false,
                        maxPeers: maxPeers,
                        hostProfile: poolManager.localProfile
                    )
                    wsTransport.sendHostAuthAfterClaim(poolInfo: poolInfo)
                    log("Claim succeeded, proceeding to HostAuth", category: .network)
                }
            }
        case .discovering:
            break
        }
    }

    public func transport(_ transport: any TransportProvider, peerDidConnect peer: TransportPeer) {
        let newPeer = Peer(
            id: peer.id,
            displayName: peer.displayName,
            isHost: false,
            connectedAt: peer.connectedAt,
            status: .connected,
            connectionType: peer.connectionType
        )
        if !connectedPeers.contains(where: { $0.id == newPeer.id }) {
            connectedPeers.append(newPeer)
        }
        // Bridge into ConnectionPoolManager so PoolChat and games see the peer
        poolManager.addRemotePeer(newPeer)
        let systemMessage = ChatMessage(
            senderID: "system",
            senderName: "System",
            text: "\(peer.displayName) joined the pool",
            isFromLocalUser: false,
            isSystemMessage: true
        )
        if !chatMessages.contains(where: { $0.id == systemMessage.id }) {
            chatMessages.append(systemMessage)
        }
    }

    public func transport(_ transport: any TransportProvider, peerDidDisconnect peerID: String) {
        let disconnectedPeer = connectedPeers.first(where: { $0.id == peerID })
        connectedPeers.removeAll { $0.id == peerID }
        // Bridge into ConnectionPoolManager
        poolManager.removeRemotePeer(peerID)
        if let name = disconnectedPeer?.effectiveDisplayName {
            let systemMessage = ChatMessage(
                senderID: "system",
                senderName: "System",
                text: "\(name) left the pool",
                isFromLocalUser: false,
                isSystemMessage: true
            )
            if !chatMessages.contains(where: { $0.id == systemMessage.id }) {
                chatMessages.append(systemMessage)
            }
        }
    }

    public func transport(_ transport: any TransportProvider, didReceiveData data: Data, from peerID: String) {
        // Decode as PoolMessage and inject into ConnectionPoolManager's pipeline.
        // This makes PoolChat and games receive the message.
        if let message = try? JSONDecoder().decode(PoolMessage.self, from: data) {
            poolManager.injectReceivedMessage(message)
            handleReceivedMessage(message)
        }
    }

    public func transport(_ transport: any TransportProvider, didDiscoverPool pool: DiscoveredPool) {
        // Remote pools are joined via invitation, not discovery. No-op.
    }

    public func transport(_ transport: any TransportProvider, didLosePool poolID: String) {
        // No-op for remote mode.
    }

    public func transport(_ transport: any TransportProvider, didReceiveJoinRequest peerID: String,
                          displayName: String, context: JoinContext) {
        let discovered = DiscoveredPeer(
            id: peerID,
            displayName: displayName,
            isInviting: false,
            hasPoolCode: false
        )

        // Auto-accept peers whose cryptographic identity (public key) was
        // already approved during this session. This handles reconnections
        // without re-prompting the host while remaining secure — the peerID
        // is relay-authenticated, not self-reported.
        if approvedPeerIDs.contains(peerID) {
            log("Auto-accepting reconnecting peer (approved ID): \(peerID.prefix(8))...", category: .network)
            acceptInvitation(discovered)
            return
        }

        if !pendingInvitations.contains(where: { $0.id == discovered.id }) {
            pendingInvitations.append(discovered)
        }
        if !autoAcceptPeers && currentInvitation == nil {
            // Dismiss the invitation share sheet if it's open so the
            // join-approval sheet can present without being blocked.
            if showInvitationShareSheet {
                showInvitationShareSheet = false
            }
            currentInvitation = discovered
            showInvitationSheet = true
        }
    }

    public func transport(_ transport: any TransportProvider, didFailWithError error: TransportError) {
        isConnectingRemote = false

        switch error {
        case .serverUnclaimed:
            // Server is fresh and needs claiming before HostAuth can proceed.
            showClaimCodeInput = true
        case .authenticationFailed where isClaimingServer:
            // Claim was rejected by the server.
            isClaimingServer = false
            showError(message: "Claim rejected. Check that the claim code is correct and has not already been used.")
        default:
            showError(message: error.localizedDescription)
        }
    }
}

// MARK: - View States

public enum ConnectionPoolViewState: Equatable {
    case home
    case browse
    case lobby
    case chat
}

// MARK: - Chat Message Model

public struct ChatMessage: Identifiable, Equatable {
    public let id: UUID
    public let senderID: String
    public let senderName: String
    public let text: String
    public let timestamp: Date
    public let isFromLocalUser: Bool
    public var isSystemMessage: Bool

    public init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        text: String,
        timestamp: Date = Date(),
        isFromLocalUser: Bool,
        isSystemMessage: Bool = false
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.timestamp = timestamp
        self.isFromLocalUser = isFromLocalUser
        self.isSystemMessage = isSystemMessage
    }

    /// Avatar color index based on sender ID
    public var avatarColorIndex: Int {
        abs(senderID.hashValue) % 8
    }
}
