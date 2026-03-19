// GamePayloads.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Game Types

/// Supported multiplayer game types
public enum MultiplayerGameType: String, Codable, Sendable, CaseIterable {
    case chainReaction = "chain_reaction"
    case connectFour = "connect_four"
    case promptParty = "prompt_party"
    case chess = "chess"

    public var displayName: String {
        switch self {
        case .chainReaction: return "Chain Reaction"
        case .connectFour: return "Connect Four"
        case .promptParty: return "Prompt Party"
        case .chess: return "Chess"
        }
    }

    public var iconName: String {
        switch self {
        case .chainReaction: return "circle.hexagongrid.fill"
        case .connectFour: return "circle.grid.3x3.fill"
        case .promptParty: return "bubble.left.and.bubble.right.fill"
        case .chess: return "crown.fill"
        }
    }

    public var maxPlayers: Int {
        switch self {
        case .chainReaction: return 2  // Currently 2, could support more
        case .connectFour: return 2     // Classic 2-player game
        case .promptParty: return 8     // Party game supports up to 8
        case .chess: return 2           // Classic 2-player game
        }
    }

    public var minPlayers: Int {
        switch self {
        case .chainReaction, .connectFour, .chess: return 2
        case .promptParty: return 2  // Party game can work with 2 players
        }
    }
}

// MARK: - Game Session

/// Represents a multiplayer game session
public struct MultiplayerGameSession: Codable, Sendable {
    public let sessionID: UUID
    public let gameType: MultiplayerGameType
    public let hostPeerID: String
    public let hostName: String
    public var players: [GamePlayer]
    public var state: GameSessionState
    public let createdAt: Date

    public init(
        sessionID: UUID = UUID(),
        gameType: MultiplayerGameType,
        hostPeerID: String,
        hostName: String,
        players: [GamePlayer] = [],
        state: GameSessionState = .waiting,
        createdAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.gameType = gameType
        self.hostPeerID = hostPeerID
        self.hostName = hostName
        self.players = players
        self.state = state
        self.createdAt = createdAt
    }

    public var canStart: Bool {
        players.count >= gameType.minPlayers && players.count <= gameType.maxPlayers
    }

    public var isFull: Bool {
        players.count >= gameType.maxPlayers
    }
}

/// Game session state
public enum GameSessionState: String, Codable, Sendable {
    case waiting = "waiting"       // Waiting for players
    case starting = "starting"     // Game is starting
    case playing = "playing"       // Game in progress
    case paused = "paused"         // Game paused
    case finished = "finished"     // Game finished
    case cancelled = "cancelled"   // Game cancelled
}

/// A player in a multiplayer game
public struct GamePlayer: Codable, Sendable, Identifiable, Equatable {
    public let id: String  // PeerID
    public let name: String
    public var playerIndex: Int  // 0-based player order
    public var isHost: Bool
    public var isReady: Bool
    public var colorIndex: Int

    /// Player's profile (optional)
    public var profile: PoolUserProfile?

    /// Effective display name (profile name if available)
    public var displayName: String {
        profile?.displayName ?? name
    }

    /// Avatar emoji from profile
    public var avatarEmoji: String? {
        profile?.avatarEmoji
    }

    /// Avatar color index from profile or fallback
    public var avatarColorIndex: Int {
        profile?.avatarColorIndex ?? colorIndex
    }

    public init(
        id: String,
        name: String,
        playerIndex: Int,
        isHost: Bool = false,
        isReady: Bool = false,
        colorIndex: Int = 0,
        profile: PoolUserProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.playerIndex = playerIndex
        self.isHost = isHost
        self.isReady = isReady
        self.colorIndex = colorIndex
        self.profile = profile
    }

    public static func == (lhs: GamePlayer, rhs: GamePlayer) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Game Invitation

/// Invitation to join a multiplayer game
public struct GameInvitation: Codable, Sendable {
    public let invitationID: UUID
    public let gameType: MultiplayerGameType
    public let hostPeerID: String
    public let hostName: String
    public let sessionID: UUID
    public let timestamp: Date

    public init(
        invitationID: UUID = UUID(),
        gameType: MultiplayerGameType,
        hostPeerID: String,
        hostName: String,
        sessionID: UUID,
        timestamp: Date = Date()
    ) {
        self.invitationID = invitationID
        self.gameType = gameType
        self.hostPeerID = hostPeerID
        self.hostName = hostName
        self.sessionID = sessionID
        self.timestamp = timestamp
    }
}

/// Response to a game invitation
public struct GameInvitationResponse: Codable, Sendable {
    public let invitationID: UUID
    public let accepted: Bool
    public let responderPeerID: String
    public let responderName: String

    public init(
        invitationID: UUID,
        accepted: Bool,
        responderPeerID: String,
        responderName: String
    ) {
        self.invitationID = invitationID
        self.accepted = accepted
        self.responderPeerID = responderPeerID
        self.responderName = responderName
    }
}

// MARK: - Chain Reaction Payloads

/// Chain Reaction game action
public struct ChainReactionAction: Codable, Sendable {
    public let cellID: Int
    public let playerIndex: Int
    public let moveNumber: Int
    public let timestamp: Date

    public init(
        cellID: Int,
        playerIndex: Int,
        moveNumber: Int,
        timestamp: Date = Date()
    ) {
        self.cellID = cellID
        self.playerIndex = playerIndex
        self.moveNumber = moveNumber
        self.timestamp = timestamp
    }
}

/// Chain Reaction game state for synchronization
public struct ChainReactionState: Codable, Sendable {
    public let sessionID: UUID
    public let cells: [ChainReactionCellState]
    public let currentPlayerIndex: Int
    public let moveCount: Int
    public let gameOver: Bool
    public let winnerIndex: Int?
    public let timestamp: Date

    public init(
        sessionID: UUID,
        cells: [ChainReactionCellState],
        currentPlayerIndex: Int,
        moveCount: Int,
        gameOver: Bool = false,
        winnerIndex: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.cells = cells
        self.currentPlayerIndex = currentPlayerIndex
        self.moveCount = moveCount
        self.gameOver = gameOver
        self.winnerIndex = winnerIndex
        self.timestamp = timestamp
    }
}

/// Chain Reaction cell state for network transmission
public struct ChainReactionCellState: Codable, Sendable {
    public let id: Int
    public let orbs: Int
    public let ownerIndex: Int?  // nil = no owner, 0 = player1, 1 = player2

    public init(id: Int, orbs: Int, ownerIndex: Int?) {
        self.id = id
        self.orbs = orbs
        self.ownerIndex = ownerIndex
    }
}

// MARK: - Connect Four Payloads

/// Connect Four game action
public struct ConnectFourAction: Codable, Sendable {
    public let column: Int
    public let playerIndex: Int
    public let moveNumber: Int
    public let timestamp: Date

    public init(
        column: Int,
        playerIndex: Int,
        moveNumber: Int,
        timestamp: Date = Date()
    ) {
        self.column = column
        self.playerIndex = playerIndex
        self.moveNumber = moveNumber
        self.timestamp = timestamp
    }
}

/// Connect Four game state for synchronization
public struct ConnectFourState: Codable, Sendable {
    public let sessionID: UUID
    public let cells: [ConnectFourCellState]
    public let currentPlayerIndex: Int
    public let moveCount: Int
    public let gameOver: Bool
    public let winnerIndex: Int?  // nil = draw if gameOver
    public let winningCells: [Int]?
    public let timestamp: Date

    public init(
        sessionID: UUID,
        cells: [ConnectFourCellState],
        currentPlayerIndex: Int,
        moveCount: Int,
        gameOver: Bool = false,
        winnerIndex: Int? = nil,
        winningCells: [Int]? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.cells = cells
        self.currentPlayerIndex = currentPlayerIndex
        self.moveCount = moveCount
        self.gameOver = gameOver
        self.winnerIndex = winnerIndex
        self.winningCells = winningCells
        self.timestamp = timestamp
    }
}

/// Connect Four cell state for network transmission
public struct ConnectFourCellState: Codable, Sendable {
    public let id: Int
    public let row: Int
    public let column: Int
    public let ownerIndex: Int?  // nil = empty, 0 = player1, 1 = player2

    public init(id: Int, row: Int, column: Int, ownerIndex: Int?) {
        self.id = id
        self.row = row
        self.column = column
        self.ownerIndex = ownerIndex
    }
}

// MARK: - Game Control Messages

/// Message types for game control
public enum GameControlType: String, Codable, Sendable {
    case invite = "invite"
    case inviteResponse = "invite_response"
    case sessionUpdate = "session_update"
    case ready = "ready"
    case start = "start"
    case pause = "pause"
    case resume = "resume"
    case forfeit = "forfeit"
    case rematch = "rematch"
}

/// Wrapper for game control messages
public struct GameControlPayload: Codable, Sendable {
    public let controlType: GameControlType
    public let gameType: MultiplayerGameType
    public let sessionID: UUID?
    public let data: Data?  // Additional data depending on control type

    public init(
        controlType: GameControlType,
        gameType: MultiplayerGameType,
        sessionID: UUID? = nil,
        data: Data? = nil
    ) {
        self.controlType = controlType
        self.gameType = gameType
        self.sessionID = sessionID
        self.data = data
    }

    /// Decode the additional data as a specific type
    public func decodeData<T: Decodable>(as type: T.Type) -> T? {
        guard let data = data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - PoolMessage Extension for Games

extension PoolMessage {
    /// Create a game control message
    public static func gameControl(
        from senderID: String,
        senderName: String,
        controlType: GameControlType,
        gameType: MultiplayerGameType,
        sessionID: UUID? = nil,
        additionalData: (any Encodable)? = nil
    ) -> PoolMessage? {
        let additionalDataEncoded: Data?
        if let additionalData = additionalData {
            additionalDataEncoded = try? JSONEncoder().encode(additionalData)
        } else {
            additionalDataEncoded = nil
        }

        let payload = GameControlPayload(
            controlType: controlType,
            gameType: gameType,
            sessionID: sessionID,
            data: additionalDataEncoded
        )

        guard let payloadData = try? JSONEncoder().encode(payload) else { return nil }

        return PoolMessage(
            type: .gameControl,  // Use dedicated gameControl type
            senderID: senderID,
            senderName: senderName,
            payload: payloadData,
            isReliable: true
        )
    }
}
