// MultiplayerGameService.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine

/// Service for managing multiplayer game sessions over ConnectionPool
@MainActor
public final class MultiplayerGameService: ObservableObject {

    // MARK: - Published Properties

    /// Current game session (if any)
    @Published public private(set) var currentSession: MultiplayerGameSession?

    /// Pending game invitation received
    @Published public private(set) var pendingInvitation: GameInvitation?

    /// Whether we're waiting for invitation response
    @Published public private(set) var isWaitingForResponse: Bool = false

    /// Whether a game is currently active
    @Published public var isGameActive: Bool = false

    /// Error message
    @Published public var errorMessage: String?

    // MARK: - Event Publishers

    /// Game action received from remote player
    public let gameActionReceived = PassthroughSubject<(action: Data, playerIndex: Int), Never>()

    /// Game state received for synchronization
    public let gameStateReceived = PassthroughSubject<Data, Never>()

    /// Game session updated (players joined/left, ready status, etc.)
    public let sessionUpdated = PassthroughSubject<MultiplayerGameSession, Never>()

    /// Game started
    public let gameStarted = PassthroughSubject<MultiplayerGameSession, Never>()

    /// Game ended
    public let gameEnded = PassthroughSubject<(session: MultiplayerGameSession, winnerIndex: Int?), Never>()

    /// Player forfeited
    public let playerForfeited = PassthroughSubject<GamePlayer, Never>()

    // MARK: - Private Properties

    public private(set) var poolManager: ConnectionPoolManager?
    private var cancellables = Set<AnyCancellable>()
    private var pendingInvitationID: UUID?
    /// Tracks players who sent ready status before being added to the session
    private var pendingReadyPeerIDs: Set<String> = []

    // MARK: - Singleton

    public static let shared = MultiplayerGameService()

    private init() {}

    /// Check if connected to a pool
    public var isPoolConnected: Bool {
        guard let poolManager = poolManager else { return false }
        return poolManager.poolState.isActive
    }

    /// Get local peer ID for player lookup
    public var localPeerID: String? {
        poolManager?.localPeerID
    }

    /// Get local peer name for display
    public var localPeerName: String? {
        poolManager?.localPeerName
    }

    // MARK: - Setup

    /// Set the connection pool manager
    public func setPoolManager(_ manager: ConnectionPoolManager) {
        self.poolManager = manager
        setupBindings()
    }

    private func setupBindings() {
        guard let poolManager = poolManager else { return }

        // Subscribe to messages
        poolManager.messageReceived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleMessage(message)
            }
            .store(in: &cancellables)

        // Subscribe to peer disconnections
        poolManager.peerEvent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handlePeerEvent(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - Game Session Management

    /// Create a new game session (host)
    public func createGameSession(gameType: MultiplayerGameType) -> MultiplayerGameSession? {
        guard let poolManager = poolManager else {
            errorMessage = "Not connected to pool"
            return nil
        }

        let hostPlayer = GamePlayer(
            id: poolManager.localPeerID,
            name: poolManager.localPeerName,
            playerIndex: 0,
            isHost: true,
            isReady: true,
            colorIndex: poolManager.localProfile.avatarColorIndex,
            profile: poolManager.localProfile
        )

        let session = MultiplayerGameSession(
            gameType: gameType,
            hostPeerID: poolManager.localPeerID,
            hostName: poolManager.localProfile.displayName,
            players: [hostPlayer],
            state: .waiting
        )

        currentSession = session
        pendingReadyPeerIDs.removeAll()
        log("Created game session: \(session.sessionID) for \(gameType.displayName)", category: .games)
        return session
    }

    /// Invite a peer to the current game session
    public func invitePeer(_ peerID: String) {
        guard let session = currentSession,
              let poolManager = poolManager else {
            errorMessage = "No active session"
            return
        }

        guard !session.isFull else {
            errorMessage = "Game is full"
            return
        }

        // Guard against sending when not in a connected state
        guard poolManager.poolState == .connected || poolManager.poolState == .hosting else {
            errorMessage = "Not connected to pool"
            log("Cannot invite peer - not in connected state (state: \(poolManager.poolState))", level: .warning, category: .games)
            return
        }

        let invitation = GameInvitation(
            gameType: session.gameType,
            hostPeerID: poolManager.localPeerID,
            hostName: poolManager.localPeerName,
            sessionID: session.sessionID
        )

        pendingInvitationID = invitation.invitationID
        isWaitingForResponse = true

        // Send invitation via game control message
        if let message = PoolMessage.gameControl(
            from: poolManager.localPeerID,
            senderName: poolManager.localPeerName,
            controlType: .invite,
            gameType: session.gameType,
            sessionID: session.sessionID,
            additionalData: invitation
        ) {
            poolManager.sendMessage(message, to: [peerID])
            log("Sent game invitation to \(peerID.prefix(8))...", category: .games)
        }
    }

    /// Invite all connected peers to the game
    public func inviteAllPeers() {
        guard let poolManager = poolManager else { return }

        for peer in poolManager.connectedPeers {
            // Don't invite ourselves
            if peer.id != poolManager.localPeerID {
                invitePeer(peer.id)
            }
        }
    }

    /// Accept a game invitation
    public func acceptInvitation(_ invitation: GameInvitation) {
        guard let poolManager = poolManager else { return }

        // Create local session as joiner first (before sending anything)
        let player = GamePlayer(
            id: poolManager.localPeerID,
            name: poolManager.localPeerName,
            playerIndex: 1,  // Will be updated when we get session update
            isHost: false,
            isReady: false,
            colorIndex: poolManager.localProfile.avatarColorIndex,
            profile: poolManager.localProfile
        )

        let session = MultiplayerGameSession(
            sessionID: invitation.sessionID,
            gameType: invitation.gameType,
            hostPeerID: invitation.hostPeerID,
            hostName: invitation.hostName,
            players: [player]
        )

        currentSession = session
        pendingInvitation = nil

        log("Accepted invitation for \(invitation.gameType.displayName)", category: .games)

        // STABILITY FIX: For non-host peers (joiners), delay sending acceptance response
        // to allow MultipeerConnectivity internal state to fully stabilize after connection.
        // This prevents "Not in connected state" errors that occur when MC operations
        // are attempted too soon after peer connection. Same fix as Pool Chat key exchange.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))

            // Re-check connection state after delay (may have disconnected)
            guard let pm = self.poolManager,
                  pm.poolState == .connected || pm.poolState == .hosting else {
                log("Connection state changed during stabilization delay, skipping invitation response", category: .games)
                return
            }

            // Send acceptance response
            let response = GameInvitationResponse(
                invitationID: invitation.invitationID,
                accepted: true,
                responderPeerID: pm.localPeerID,
                responderName: pm.localProfile.displayName
            )

            if let message = PoolMessage.gameControl(
                from: pm.localPeerID,
                senderName: pm.localProfile.displayName,
                controlType: .inviteResponse,
                gameType: invitation.gameType,
                sessionID: invitation.sessionID,
                additionalData: response
            ) {
                pm.sendMessage(message, to: [invitation.hostPeerID])
                log("Sent invitation acceptance to host after stabilization delay", category: .games)
            }
        }
    }

    /// Decline a game invitation
    public func declineInvitation(_ invitation: GameInvitation) {
        guard let poolManager = poolManager else { return }

        // Guard against sending when not in a connected state
        guard poolManager.poolState == .connected || poolManager.poolState == .hosting else {
            log("Cannot decline invitation - not in connected state (state: \(poolManager.poolState))", level: .warning, category: .games)
            pendingInvitation = nil
            return
        }

        let response = GameInvitationResponse(
            invitationID: invitation.invitationID,
            accepted: false,
            responderPeerID: poolManager.localPeerID,
            responderName: poolManager.localPeerName
        )

        if let message = PoolMessage.gameControl(
            from: poolManager.localPeerID,
            senderName: poolManager.localPeerName,
            controlType: .inviteResponse,
            gameType: invitation.gameType,
            sessionID: invitation.sessionID,
            additionalData: response
        ) {
            poolManager.sendMessage(message, to: [invitation.hostPeerID])
        }

        pendingInvitation = nil
        log("Declined invitation for \(invitation.gameType.displayName)", category: .games)
    }

    /// Set ready status
    public func setReady(_ ready: Bool) {
        guard var session = currentSession,
              let poolManager = poolManager else { return }

        // Update local player's ready status locally first
        if let index = session.players.firstIndex(where: { $0.id == poolManager.localPeerID }) {
            session.players[index].isReady = ready
            currentSession = session

            // Guard against sending when not in a connected state
            guard poolManager.poolState == .connected || poolManager.poolState == .hosting else {
                log("Cannot send ready status - not in connected state (state: \(poolManager.poolState))", level: .warning, category: .games)
                return
            }

            // Send a dedicated ready message instead of broadcasting the entire session
            // This prevents non-hosts from accidentally overwriting the host's authoritative session
            if let message = PoolMessage.gameControl(
                from: poolManager.localPeerID,
                senderName: poolManager.localPeerName,
                controlType: .ready,
                gameType: session.gameType,
                sessionID: session.sessionID
            ) {
                poolManager.sendMessage(message)
            }
        }
    }

    /// Start the game (host only)
    public func startGame() {
        guard var session = currentSession,
              let poolManager = poolManager,
              session.hostPeerID == poolManager.localPeerID else {
            errorMessage = "Only host can start the game"
            return
        }

        guard session.canStart else {
            errorMessage = "Not enough players to start"
            return
        }

        // Check all players ready
        let allReady = session.players.allSatisfy { $0.isReady }
        guard allReady else {
            errorMessage = "Not all players are ready"
            return
        }

        // Guard against sending when not in a connected state
        guard poolManager.poolState == .connected || poolManager.poolState == .hosting else {
            errorMessage = "Not connected to pool"
            log("Cannot start game - not in connected state (state: \(poolManager.poolState))", level: .warning, category: .games)
            return
        }

        session.state = .playing
        currentSession = session
        isGameActive = true

        // Broadcast game start
        if let message = PoolMessage.gameControl(
            from: poolManager.localPeerID,
            senderName: poolManager.localPeerName,
            controlType: .start,
            gameType: session.gameType,
            sessionID: session.sessionID,
            additionalData: session
        ) {
            poolManager.sendMessage(message)
        }

        gameStarted.send(session)
        log("Game started: \(session.gameType.displayName)", category: .games)
    }

    /// Send a game action to other players
    public func sendGameAction<T: Encodable>(_ action: T) {
        guard currentSession != nil,
              let poolManager = poolManager else { return }

        // Guard against sending when not in a connected state
        guard poolManager.poolState == .connected || poolManager.poolState == .hosting else {
            log("Cannot send game action - not in connected state (state: \(poolManager.poolState))", level: .warning, category: .games)
            return
        }

        if let message = PoolMessage.gameAction(
            from: poolManager.localPeerID,
            senderName: poolManager.localPeerName,
            action: action,
            reliable: true
        ) {
            poolManager.sendMessage(message)
        }
    }

    /// Send current game state for synchronization
    public func sendGameState<T: Encodable>(_ state: T) {
        guard currentSession != nil,
              let poolManager = poolManager else { return }

        // Guard against sending when not in a connected state
        guard poolManager.poolState == .connected || poolManager.poolState == .hosting else {
            log("Cannot send game state - not in connected state (state: \(poolManager.poolState))", level: .warning, category: .games)
            return
        }

        if let message = PoolMessage.gameState(
            from: poolManager.localPeerID,
            senderName: poolManager.localPeerName,
            state: state
        ) {
            poolManager.sendMessage(message)
        }
    }

    /// End the current game
    public func endGame(winnerIndex: Int?) {
        guard var session = currentSession else { return }

        session.state = .finished
        currentSession = session
        isGameActive = false

        gameEnded.send((session: session, winnerIndex: winnerIndex))
        log("Game ended. Winner: \(winnerIndex.map { String($0) } ?? "draw")", category: .games)
    }

    /// Forfeit the current game
    public func forfeit() {
        guard let session = currentSession,
              let poolManager = poolManager else { return }

        // Only send forfeit message if connected (otherwise just end locally)
        if poolManager.poolState == .connected || poolManager.poolState == .hosting {
            if let message = PoolMessage.gameControl(
                from: poolManager.localPeerID,
                senderName: poolManager.localPeerName,
                controlType: .forfeit,
                gameType: session.gameType,
                sessionID: session.sessionID
            ) {
                poolManager.sendMessage(message)
            }
        } else {
            log("Cannot send forfeit message - not in connected state, ending game locally", level: .warning, category: .games)
        }

        // End game with us as loser
        let _ = session.players.firstIndex(where: { $0.id == poolManager.localPeerID })
        let winnerIndex = session.players.first(where: { $0.id != poolManager.localPeerID })?.playerIndex
        endGame(winnerIndex: winnerIndex)
    }

    /// Leave the current game session
    public func leaveSession() {
        currentSession = nil
        isGameActive = false
        pendingInvitation = nil
        isWaitingForResponse = false
        pendingReadyPeerIDs.removeAll()
        log("Left game session", category: .games)
    }

    // MARK: - Helper Methods

    /// Get local player index in current session
    public var localPlayerIndex: Int? {
        guard let session = currentSession,
              let poolManager = poolManager else { return nil }
        return session.players.first(where: { $0.id == poolManager.localPeerID })?.playerIndex
    }

    /// Check if it's local player's turn (for turn-based games)
    public func isMyTurn(currentTurnIndex: Int) -> Bool {
        guard let myIndex = localPlayerIndex else { return false }
        return myIndex == currentTurnIndex
    }

    /// Check if local player is the host
    public var isHost: Bool {
        guard let session = currentSession,
              let poolManager = poolManager else { return false }
        return session.hostPeerID == poolManager.localPeerID
    }

    /// Get available peers for player selection (excludes self)
    public var availablePeers: [Peer] {
        guard let poolManager = poolManager else { return [] }
        return poolManager.connectedPeers.filter { $0.id != poolManager.localPeerID }
    }

    /// Get the count of available opponents
    public var availableOpponentCount: Int {
        availablePeers.count
    }

    // MARK: - Private Methods

    private func broadcastSessionUpdate() {
        guard let session = currentSession,
              let poolManager = poolManager else { return }

        // Guard against sending when not in a connected state
        guard poolManager.poolState == .connected || poolManager.poolState == .hosting else {
            log("Cannot broadcast session update - not in connected state (state: \(poolManager.poolState))", level: .warning, category: .games)
            return
        }

        if let message = PoolMessage.gameControl(
            from: poolManager.localPeerID,
            senderName: poolManager.localPeerName,
            controlType: .sessionUpdate,
            gameType: session.gameType,
            sessionID: session.sessionID,
            additionalData: session
        ) {
            poolManager.sendMessage(message)
        }
    }

    private func handleMessage(_ message: PoolMessage) {
        switch message.type {
        case .gameControl:
            handleGameControlMessage(message)
        case .gameState:
            handleGameStateMessage(message)
        case .gameAction:
            handleGameActionMessage(message)
        default:
            break
        }
    }

    private func handleGameControlMessage(_ message: PoolMessage) {
        // Decode as game control payload
        guard let control = message.decodePayload(as: GameControlPayload.self) else {
            log("Failed to decode game control payload", category: .games)
            return
        }
        handleGameControl(control, from: message.senderID, senderName: message.senderName)
    }

    private func handleGameStateMessage(_ message: PoolMessage) {
        // This is a raw game state update for synchronization
        gameStateReceived.send(message.payload)
    }

    private func handleGameActionMessage(_ message: PoolMessage) {
        guard let session = currentSession else { return }

        // SECURITY: Use transport-authenticated senderID (message.senderID) for player lookup.
        // This is the peer ID from the transport layer, not a self-reported field in the payload.
        // This prevents players from impersonating other players by crafting malicious payloads.
        guard let playerIndex = session.players.first(where: { $0.id == message.senderID })?.playerIndex else {
            log("[SECURITY] Received game action from unknown player \(message.senderID.prefix(8))..., dropping",
                level: .warning, category: .games)
            return
        }
        gameActionReceived.send((action: message.payload, playerIndex: playerIndex))
    }

    private func handleGameControl(_ control: GameControlPayload, from senderID: String, senderName: String) {
        switch control.controlType {
        case .invite:
            if let invitation = control.decodeData(as: GameInvitation.self) {
                pendingInvitation = invitation
                log("Received game invitation from \(senderName)", category: .games)
            }

        case .inviteResponse:
            if let response = control.decodeData(as: GameInvitationResponse.self) {
                handleInvitationResponse(response)
            }

        case .sessionUpdate:
            // SECURITY: Only the host can send authoritative session updates.
            // Use the transport-authenticated senderID (not self-reported) to verify.
            guard let session = currentSession else { break }
            guard senderID == session.hostPeerID else {
                log("[SECURITY] Rejecting sessionUpdate from non-host peer \(senderID.prefix(8))... (host is \(session.hostPeerID.prefix(8))...)",
                    level: .warning, category: .games)
                break
            }
            if let updatedSession = control.decodeData(as: MultiplayerGameSession.self) {
                currentSession = updatedSession
                sessionUpdated.send(updatedSession)
            }

        case .start:
            // SECURITY: Only the host can start the game.
            guard let session = currentSession else { break }
            guard senderID == session.hostPeerID else {
                log("[SECURITY] Rejecting start command from non-host peer \(senderID.prefix(8))... (host is \(session.hostPeerID.prefix(8))...)",
                    level: .warning, category: .games)
                break
            }
            if let startedSession = control.decodeData(as: MultiplayerGameSession.self) {
                currentSession = startedSession
                isGameActive = true
                gameStarted.send(startedSession)
                log("Game started by host", category: .games)
            }

        case .ready:
            // Handle ready status update.
            // Use transport-authenticated senderID for player lookup instead of self-reported data.
            if var session = currentSession {
                if let playerIndex = session.players.firstIndex(where: { $0.id == senderID }) {
                    session.players[playerIndex].isReady = true
                    currentSession = session
                    sessionUpdated.send(session)
                } else {
                    // Player not in session yet (race condition) - store for later
                    pendingReadyPeerIDs.insert(senderID)
                }
            }

        case .forfeit:
            // Use transport-authenticated senderID for player lookup.
            if let session = currentSession,
               let player = session.players.first(where: { $0.id == senderID }) {
                playerForfeited.send(player)
                // End game with forfeiting player as loser
                let winnerIndex = session.players.first(where: { $0.id != senderID })?.playerIndex
                endGame(winnerIndex: winnerIndex)
            }

        case .pause, .resume, .rematch:
            break
        }
    }

    private func handleInvitationResponse(_ response: GameInvitationResponse) {
        isWaitingForResponse = false

        if response.accepted {
            // Add player to session
            if var session = currentSession {
                // Try to get profile from connected peers
                let peerProfile = poolManager?.connectedPeers.first(where: { $0.id == response.responderPeerID })?.profile

                // Check if this player already sent a ready message (race condition handling)
                let isPendingReady = pendingReadyPeerIDs.remove(response.responderPeerID) != nil

                let newPlayer = GamePlayer(
                    id: response.responderPeerID,
                    name: response.responderName,
                    playerIndex: session.players.count,
                    isHost: false,
                    isReady: isPendingReady,
                    colorIndex: peerProfile?.avatarColorIndex ?? session.players.count,
                    profile: peerProfile
                )
                session.players.append(newPlayer)
                currentSession = session
                broadcastSessionUpdate()
                sessionUpdated.send(session)
                log("\(response.responderName) joined the game", category: .games)
            }
        } else {
            log("\(response.responderName) declined the invitation", category: .games)
        }

        pendingInvitationID = nil
    }

    private func handlePeerEvent(_ event: PeerEvent) {
        switch event {
        case .disconnected(let peer):
            // Handle player disconnect during game
            if var session = currentSession,
               let playerIndex = session.players.firstIndex(where: { $0.id == peer.id }) {
                let player = session.players[playerIndex]
                session.players.remove(at: playerIndex)
                currentSession = session

                if isGameActive {
                    // Player disconnected during game - they forfeit
                    playerForfeited.send(player)
                    let winnerIndex = session.players.first?.playerIndex
                    endGame(winnerIndex: winnerIndex)
                } else {
                    sessionUpdated.send(session)
                }
            }

        default:
            break
        }
    }
}
