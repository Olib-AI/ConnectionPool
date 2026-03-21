// ServerFrame.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Server Frame

/// Wire protocol frames exchanged between the iOS client and the StealthRelay server.
///
/// Encoded as JSON with an internally-tagged discriminator using `frame_type` as the tag
/// and `data` as the content key. This matches the Rust serde attribute:
/// `#[serde(tag = "frame_type", content = "data", rename_all = "snake_case")]`
///
/// All variant names use `snake_case` in JSON to match the Rust server.
public enum ServerFrame: Sendable, Equatable {

    // MARK: - Client -> Server

    /// Authenticate as the pool host with an Ed25519 signature.
    case hostAuth(HostAuthData)

    /// Request to join a pool using an invitation token.
    case joinRequest(JoinRequestData)

    /// Forward opaque E2E-encrypted application data to peer(s).
    case forward(ForwardData)

    /// Host kicks a peer from the pool.
    case kickPeer(KickPeerData)

    /// Host requests creation of an invitation token.
    case createInvitation(CreateInvitationData)

    /// Host revokes an existing invitation token.
    case revokeInvitation(RevokeInvitationData)

    /// Host approves or rejects a pending join request.
    case joinApproval(JoinApprovalData)

    /// Acknowledge receipt of a message sequence number.
    case ack(AckData)

    /// Close the pool (host only).
    case closePool(ClosePoolData? = nil)

    /// Client handshake init (Noise NK step 1).
    case handshakeInit(HandshakeInitData)

    /// Heartbeat ping to keep the connection alive.
    case heartbeatPing(HeartbeatPingData)

    /// Claim an unclaimed server by providing the one-time claim secret.
    case claimServer(ClaimServerData)

    // MARK: - Server -> Client

    /// Server hello with optional proof-of-work challenge.
    case serverHello(ServerHelloData)

    /// Host authentication succeeded.
    case hostAuthSuccess(HostAuthSuccessData)

    /// Join request was accepted by the host.
    case joinAccepted(JoinAcceptedData)

    /// Join request was rejected by the host.
    case joinRejected(JoinRejectedData)

    /// A new peer joined the pool.
    case peerJoined(PeerJoinedData)

    /// A peer left the pool.
    case peerLeft(PeerLeftData)

    /// Data relayed from another peer.
    case relayed(RelayedData)

    /// Invitation token was created successfully.
    case invitationCreated(InvitationCreatedData)

    /// Forward a join request to the host for approval decision.
    case joinRequestForHost(JoinRequestForHostData)

    /// Session was resumed after a reconnection with buffered messages.
    case sessionResumed(SessionResumedData)

    /// Server error.
    case error(ErrorData)

    /// Server-initiated kick.
    case kicked(KickedData)

    /// Heartbeat pong response from server.
    case heartbeatPong(HeartbeatPongData)

    /// Server confirmed the claim was successful.
    case claimSuccess(ClaimSuccessData)

    /// Server rejected the claim attempt.
    case claimRejected(ClaimRejectedData)
}

// MARK: - Associated Data Types

/// Host authentication payload sent by the pool creator.
public struct HostAuthData: Codable, Sendable, Equatable {
    /// Base64-encoded Ed25519 public key of the host.
    public let hostPublicKey: String

    /// Unix timestamp (seconds) when the auth was created.
    public let timestamp: Int64

    /// Base64-encoded Ed25519 signature over `pool_id || timestamp`.
    public let signature: String

    /// The pool identifier to authenticate for.
    public let poolId: UUID

    /// The server URL as seen by the host (e.g., "ws://10.0.0.4:9090").
    /// Used to embed in invitation URLs so joiners know where to connect.
    public let serverUrl: String?

    /// The host's display name shown to other pool members.
    public let displayName: String?

    public init(hostPublicKey: String, timestamp: Int64, signature: String, poolId: UUID, serverUrl: String? = nil, displayName: String? = nil) {
        self.hostPublicKey = hostPublicKey
        self.timestamp = timestamp
        self.signature = signature
        self.poolId = poolId
        self.serverUrl = serverUrl
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case hostPublicKey = "host_public_key"
        case timestamp
        case signature
        case poolId = "pool_id"
        case serverUrl = "server_url"
        case displayName = "display_name"
    }
}

/// Join request payload sent by a peer wanting to join a pool.
public struct JoinRequestData: Codable, Sendable, Equatable {
    /// The token identifier from the invitation.
    public let tokenId: String

    /// Base64-encoded HMAC proof of token possession.
    public let proof: String

    /// Unix timestamp of proof creation.
    public let timestamp: Int64

    /// Base64-encoded random nonce used in proof computation.
    public let nonce: String

    /// Base64-encoded public key of the joining client.
    public let clientPublicKey: String

    /// Display name of the joining client.
    public let displayName: String

    /// Optional proof-of-work solution if the server issued a challenge.
    public let powSolution: PowSolutionData?

    public init(
        tokenId: String, proof: String, timestamp: Int64, nonce: String,
        clientPublicKey: String, displayName: String, powSolution: PowSolutionData? = nil
    ) {
        self.tokenId = tokenId
        self.proof = proof
        self.timestamp = timestamp
        self.nonce = nonce
        self.clientPublicKey = clientPublicKey
        self.displayName = displayName
        self.powSolution = powSolution
    }

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case proof
        case timestamp
        case nonce
        case clientPublicKey = "client_public_key"
        case displayName = "display_name"
        case powSolution = "pow_solution"
    }
}

/// Forward payload carrying opaque E2E-encrypted data to relay to peers.
public struct ForwardData: Codable, Sendable, Equatable {
    /// Base64-encoded opaque data (typically a serialized ``PoolMessage``).
    public let data: String

    /// Target peer IDs. If nil, broadcasts to all peers in the pool.
    public let targetPeerIds: [String]?

    /// Monotonic sequence number for ordering and acknowledgement.
    public let sequence: UInt64

    /// Session token for host-originated forwards. Guests don't need this.
    public var sessionToken: String?

    public init(data: String, targetPeerIds: [String]? = nil, sequence: UInt64, sessionToken: String? = nil) {
        self.data = data
        self.targetPeerIds = targetPeerIds
        self.sequence = sequence
        self.sessionToken = sessionToken
    }

    enum CodingKeys: String, CodingKey {
        case data
        case targetPeerIds = "target_peer_ids"
        case sequence
        case sessionToken = "session_token"
    }
}

/// Kick peer payload sent by the host.
public struct KickPeerData: Codable, Sendable, Equatable {
    /// The peer to kick.
    public let peerId: String

    /// Human-readable reason for the kick.
    public let reason: String

    /// Session token for host authentication.
    public var sessionToken: String?

    public init(peerId: String, reason: String, sessionToken: String? = nil) {
        self.peerId = peerId
        self.reason = reason
        self.sessionToken = sessionToken
    }

    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id"
        case reason
        case sessionToken = "session_token"
    }
}

/// Create invitation payload sent by the host.
public struct CreateInvitationData: Codable, Sendable, Equatable {
    /// Maximum number of times this invitation can be used.
    public let maxUses: UInt8

    /// How long the invitation is valid for, in seconds.
    public let expiresInSecs: UInt64

    /// Session token for host authentication.
    public var sessionToken: String?

    public init(maxUses: UInt8, expiresInSecs: UInt64, sessionToken: String? = nil) {
        self.maxUses = maxUses
        self.expiresInSecs = expiresInSecs
        self.sessionToken = sessionToken
    }

    enum CodingKeys: String, CodingKey {
        case maxUses = "max_uses"
        case expiresInSecs = "expires_in_secs"
        case sessionToken = "session_token"
    }
}

/// Revoke invitation payload sent by the host.
public struct RevokeInvitationData: Codable, Sendable, Equatable {
    /// The token ID of the invitation to revoke.
    public let tokenId: String

    /// Session token for host authentication.
    public var sessionToken: String?

    public init(tokenId: String, sessionToken: String? = nil) {
        self.tokenId = tokenId
        self.sessionToken = sessionToken
    }

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case sessionToken = "session_token"
    }
}

/// Join approval payload sent by the host in response to a join request.
public struct JoinApprovalData: Codable, Sendable, Equatable {
    /// The public key of the client being approved or rejected.
    public let clientPublicKey: String

    /// Whether the join request is approved.
    public let approved: Bool

    /// Optional reason for rejection.
    public let reason: String?

    /// Session token for host authentication.
    public var sessionToken: String?

    public init(clientPublicKey: String, approved: Bool, reason: String? = nil, sessionToken: String? = nil) {
        self.clientPublicKey = clientPublicKey
        self.approved = approved
        self.reason = reason
        self.sessionToken = sessionToken
    }

    enum CodingKeys: String, CodingKey {
        case clientPublicKey = "client_public_key"
        case approved
        case reason
        case sessionToken = "session_token"
    }
}

/// Acknowledgement payload for confirming receipt of a sequence number.
public struct AckData: Codable, Sendable, Equatable {
    /// The sequence number being acknowledged.
    public let sequence: UInt64

    public init(sequence: UInt64) {
        self.sequence = sequence
    }
}

/// Close pool payload sent by the host.
public struct ClosePoolData: Codable, Sendable, Equatable {
    /// Session token for host authentication.
    public var sessionToken: String?

    public init(sessionToken: String? = nil) {
        self.sessionToken = sessionToken
    }

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
    }
}

/// Client handshake init payload (Noise NK step 1).
public struct HandshakeInitData: Codable, Sendable, Equatable {
    /// Base64-encoded ephemeral public key.
    public let clientEphemeralPk: String

    /// Base64-encoded identity public key.
    public let clientIdentityPk: String

    /// Unix timestamp.
    public let timestamp: Int64

    /// Base64-encoded signature.
    public let signature: String

    public init(clientEphemeralPk: String, clientIdentityPk: String, timestamp: Int64, signature: String) {
        self.clientEphemeralPk = clientEphemeralPk
        self.clientIdentityPk = clientIdentityPk
        self.timestamp = timestamp
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case clientEphemeralPk = "client_ephemeral_pk"
        case clientIdentityPk = "client_identity_pk"
        case timestamp
        case signature
    }
}

/// Heartbeat ping payload to keep the WebSocket alive.
public struct HeartbeatPingData: Codable, Sendable, Equatable {
    /// Unix timestamp of the ping.
    public let timestamp: Int64

    public init(timestamp: Int64) {
        self.timestamp = timestamp
    }
}

/// Server hello payload with optional proof-of-work challenge.
public struct ServerHelloData: Codable, Sendable, Equatable {
    /// Base64-encoded server ephemeral public key.
    public let serverEphemeralPk: String

    /// Base64-encoded server identity public key.
    public let serverIdentityPk: String

    /// Optional proof-of-work challenge.
    public let powChallenge: PowChallengeData?

    /// Unix timestamp.
    public let timestamp: Int64

    /// Base64-encoded server signature.
    public let signature: String

    public init(
        serverEphemeralPk: String, serverIdentityPk: String,
        powChallenge: PowChallengeData?, timestamp: Int64, signature: String
    ) {
        self.serverEphemeralPk = serverEphemeralPk
        self.serverIdentityPk = serverIdentityPk
        self.powChallenge = powChallenge
        self.timestamp = timestamp
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case serverEphemeralPk = "server_ephemeral_pk"
        case serverIdentityPk = "server_identity_pk"
        case powChallenge = "pow_challenge"
        case timestamp
        case signature
    }
}

/// Host authentication success response from the server.
public struct HostAuthSuccessData: Codable, Sendable, Equatable {
    /// The pool ID that was authenticated.
    public let poolId: UUID

    /// Session token for reconnection.
    public let sessionToken: String

    public init(poolId: UUID, sessionToken: String) {
        self.poolId = poolId
        self.sessionToken = sessionToken
    }

    enum CodingKeys: String, CodingKey {
        case poolId = "pool_id"
        case sessionToken = "session_token"
    }
}

/// Join accepted response from the server.
public struct JoinAcceptedData: Codable, Sendable, Equatable {
    /// Session token for this connection (used for reconnection).
    public let sessionToken: String

    /// The peer ID assigned to the joining client.
    public let peerId: String

    /// List of peers already in the pool.
    public let peers: [ServerPeerInfo]

    /// Information about the pool.
    public let poolInfo: ServerPoolInfo

    public init(sessionToken: String, peerId: String, peers: [ServerPeerInfo], poolInfo: ServerPoolInfo) {
        self.sessionToken = sessionToken
        self.peerId = peerId
        self.peers = peers
        self.poolInfo = poolInfo
    }

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case peerId = "peer_id"
        case peers
        case poolInfo = "pool_info"
    }
}

/// Join rejected response from the server.
public struct JoinRejectedData: Codable, Sendable, Equatable {
    /// Human-readable reason for rejection.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// Notification that a new peer joined the pool.
public struct PeerJoinedData: Codable, Sendable, Equatable {
    /// Information about the peer that joined.
    public let peer: ServerPeerInfo

    public init(peer: ServerPeerInfo) {
        self.peer = peer
    }
}

/// Notification that a peer left the pool.
public struct PeerLeftData: Codable, Sendable, Equatable {
    /// The identifier of the peer that left.
    public let peerId: String

    /// The reason the peer left (e.g., "disconnected", "kicked").
    public let reason: String

    public init(peerId: String, reason: String) {
        self.peerId = peerId
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id"
        case reason
    }
}

/// Data relayed from another peer through the server.
public struct RelayedData: Codable, Sendable, Equatable {
    /// Base64-encoded opaque data from the sending peer.
    public let data: String

    /// The peer ID of the sender.
    public let fromPeerId: String

    /// Sequence number for ordering.
    public let sequence: UInt64

    public init(data: String, fromPeerId: String, sequence: UInt64) {
        self.data = data
        self.fromPeerId = fromPeerId
        self.sequence = sequence
    }

    enum CodingKeys: String, CodingKey {
        case data
        case fromPeerId = "from_peer_id"
        case sequence
    }
}

/// Invitation created response from the server.
public struct InvitationCreatedData: Codable, Sendable, Equatable {
    /// The unique token identifier.
    public let tokenId: String

    /// The invitation URL to share with invitees.
    public let url: String

    /// Unix timestamp when the invitation expires.
    public let expiresAt: Int64

    public init(tokenId: String, url: String, expiresAt: Int64) {
        self.tokenId = tokenId
        self.url = url
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case tokenId = "token_id"
        case url
        case expiresAt = "expires_at"
    }
}

/// Join request forwarded to the host for approval.
public struct JoinRequestForHostData: Codable, Sendable, Equatable {
    /// Base64-encoded public key of the requesting client.
    public let clientPublicKey: String

    /// The invitation token ID used.
    public let tokenId: String

    /// Base64-encoded HMAC proof of token possession.
    public let proof: String

    /// Unix timestamp of the proof.
    public let timestamp: Int64

    /// Base64-encoded nonce used in proof computation.
    public let nonce: String

    /// Display name of the requesting client.
    public let displayName: String

    public init(
        clientPublicKey: String, tokenId: String, proof: String,
        timestamp: Int64, nonce: String, displayName: String
    ) {
        self.clientPublicKey = clientPublicKey
        self.tokenId = tokenId
        self.proof = proof
        self.timestamp = timestamp
        self.nonce = nonce
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case clientPublicKey = "client_public_key"
        case tokenId = "token_id"
        case proof
        case timestamp
        case nonce
        case displayName = "display_name"
    }
}

/// Session resumed after reconnection with any missed messages.
public struct SessionResumedData: Codable, Sendable, Equatable {
    /// Messages that were buffered while the client was disconnected.
    public let missedMessages: [ServerFrame]

    /// The last sequence number the server acknowledged from this client.
    public let lastAckedSequence: UInt64

    public init(missedMessages: [ServerFrame], lastAckedSequence: UInt64) {
        self.missedMessages = missedMessages
        self.lastAckedSequence = lastAckedSequence
    }

    enum CodingKeys: String, CodingKey {
        case missedMessages = "missed_messages"
        case lastAckedSequence = "last_acked_sequence"
    }
}

/// Error frame from the server.
public struct ErrorData: Codable, Sendable, Equatable {
    /// Numeric error code.
    public let code: UInt32

    /// Human-readable error message.
    public let message: String

    public init(code: UInt32, message: String) {
        self.code = code
        self.message = message
    }
}

/// Kicked notification from the server.
public struct KickedData: Codable, Sendable, Equatable {
    /// Human-readable reason for being kicked.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

/// Heartbeat pong response from the server.
public struct HeartbeatPongData: Codable, Sendable, Equatable {
    /// The original timestamp from the ping.
    public let timestamp: Int64

    /// The server's current time.
    public let serverTime: Int64

    public init(timestamp: Int64, serverTime: Int64) {
        self.timestamp = timestamp
        self.serverTime = serverTime
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case serverTime = "server_time"
    }
}

/// Claim server payload sent by the operator to bind their identity to a fresh server.
public struct ClaimServerData: Codable, Sendable, Equatable {
    /// The 64-character hex claim secret from the server's Docker logs.
    public let claimSecret: String

    /// Base64-encoded Ed25519 public key of the host claiming the server.
    public let hostPublicKey: String

    /// Human-readable display name of the host.
    public let displayName: String

    public init(claimSecret: String, hostPublicKey: String, displayName: String) {
        self.claimSecret = claimSecret
        self.hostPublicKey = hostPublicKey
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case claimSecret = "claim_secret"
        case hostPublicKey = "host_public_key"
        case displayName = "display_name"
    }
}

/// Server response confirming the claim was successful.
public struct ClaimSuccessData: Codable, Sendable, Equatable {
    /// The server's fingerprint for future identification.
    public let serverFingerprint: String

    /// Human-readable success message from the server.
    public let message: String

    public init(serverFingerprint: String, message: String) {
        self.serverFingerprint = serverFingerprint
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case serverFingerprint = "server_fingerprint"
        case message
    }
}

/// Server response rejecting the claim attempt.
public struct ClaimRejectedData: Codable, Sendable, Equatable {
    /// The reason the claim was rejected.
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

// MARK: - Supporting Types

/// Information about a connected peer, as reported by the server.
public struct ServerPeerInfo: Codable, Sendable, Equatable {
    /// The peer's unique identifier.
    public let peerId: String

    /// The peer's display name.
    public let displayName: String

    /// Base64-encoded public key of the peer.
    public let publicKey: String

    /// Unix timestamp when the peer connected.
    public let connectedAt: Int64

    public init(peerId: String, displayName: String, publicKey: String, connectedAt: Int64) {
        self.peerId = peerId
        self.displayName = displayName
        self.publicKey = publicKey
        self.connectedAt = connectedAt
    }

    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id"
        case displayName = "display_name"
        case publicKey = "public_key"
        case connectedAt = "connected_at"
    }
}

/// Summary information about a pool, as reported by the server.
public struct ServerPoolInfo: Codable, Sendable, Equatable {
    /// The pool's unique identifier.
    public let poolId: UUID

    /// The pool's name.
    public let name: String

    /// The peer ID of the pool host.
    public let hostPeerId: String

    /// Maximum number of peers in the pool.
    public let maxPeers: Int

    /// Current number of connected peers.
    public let currentPeers: Int

    public init(poolId: UUID, name: String, hostPeerId: String, maxPeers: Int, currentPeers: Int) {
        self.poolId = poolId
        self.name = name
        self.hostPeerId = hostPeerId
        self.maxPeers = maxPeers
        self.currentPeers = currentPeers
    }

    enum CodingKeys: String, CodingKey {
        case poolId = "pool_id"
        case name
        case hostPeerId = "host_peer_id"
        case maxPeers = "max_peers"
        case currentPeers = "current_peers"
    }
}

/// Proof-of-work challenge issued by the server to prevent abuse.
public struct PowChallengeData: Codable, Sendable, Equatable {
    /// The challenge string to solve.
    public let challenge: String

    /// Required difficulty (number of leading zero bits).
    public let difficulty: UInt8

    /// Unix timestamp of challenge issuance.
    public let timestamp: Int64

    public init(challenge: String, difficulty: UInt8, timestamp: Int64) {
        self.challenge = challenge
        self.difficulty = difficulty
        self.timestamp = timestamp
    }
}

/// Proof-of-work solution submitted by the client.
public struct PowSolutionData: Codable, Sendable, Equatable {
    /// The original challenge string.
    public let challenge: String

    /// The solution that satisfies the difficulty requirement.
    public let solution: String

    public init(challenge: String, solution: String) {
        self.challenge = challenge
        self.solution = solution
    }
}

// MARK: - Codable Conformance

extension ServerFrame: Codable {

    /// JSON discriminator tag values matching the Rust `#[serde(rename_all = "snake_case")]` attribute.
    private enum FrameType: String, Codable {
        case hostAuth = "host_auth"
        case joinRequest = "join_request"
        case forward
        case kickPeer = "kick_peer"
        case createInvitation = "create_invitation"
        case revokeInvitation = "revoke_invitation"
        case joinApproval = "join_approval"
        case ack
        case closePool = "close_pool"
        case handshakeInit = "handshake_init"
        case heartbeatPing = "heartbeat_ping"
        case claimServer = "claim_server"
        case serverHello = "server_hello"
        case hostAuthSuccess = "host_auth_success"
        case joinAccepted = "join_accepted"
        case joinRejected = "join_rejected"
        case peerJoined = "peer_joined"
        case peerLeft = "peer_left"
        case relayed
        case invitationCreated = "invitation_created"
        case joinRequestForHost = "join_request_for_host"
        case sessionResumed = "session_resumed"
        case error
        case kicked
        case heartbeatPong = "heartbeat_pong"
        case claimSuccess = "claim_success"
        case claimRejected = "claim_rejected"
    }

    private enum CodingKeys: String, CodingKey {
        case frameType = "frame_type"
        case data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frameType = try container.decode(FrameType.self, forKey: .frameType)

        switch frameType {
        case .hostAuth:
            self = .hostAuth(try container.decode(HostAuthData.self, forKey: .data))
        case .joinRequest:
            self = .joinRequest(try container.decode(JoinRequestData.self, forKey: .data))
        case .forward:
            self = .forward(try container.decode(ForwardData.self, forKey: .data))
        case .kickPeer:
            self = .kickPeer(try container.decode(KickPeerData.self, forKey: .data))
        case .createInvitation:
            self = .createInvitation(try container.decode(CreateInvitationData.self, forKey: .data))
        case .revokeInvitation:
            self = .revokeInvitation(try container.decode(RevokeInvitationData.self, forKey: .data))
        case .joinApproval:
            self = .joinApproval(try container.decode(JoinApprovalData.self, forKey: .data))
        case .ack:
            self = .ack(try container.decode(AckData.self, forKey: .data))
        case .closePool:
            self = .closePool(try container.decodeIfPresent(ClosePoolData.self, forKey: .data))
        case .handshakeInit:
            self = .handshakeInit(try container.decode(HandshakeInitData.self, forKey: .data))
        case .heartbeatPing:
            self = .heartbeatPing(try container.decode(HeartbeatPingData.self, forKey: .data))
        case .claimServer:
            self = .claimServer(try container.decode(ClaimServerData.self, forKey: .data))
        case .serverHello:
            self = .serverHello(try container.decode(ServerHelloData.self, forKey: .data))
        case .hostAuthSuccess:
            self = .hostAuthSuccess(try container.decode(HostAuthSuccessData.self, forKey: .data))
        case .joinAccepted:
            self = .joinAccepted(try container.decode(JoinAcceptedData.self, forKey: .data))
        case .joinRejected:
            self = .joinRejected(try container.decode(JoinRejectedData.self, forKey: .data))
        case .peerJoined:
            self = .peerJoined(try container.decode(PeerJoinedData.self, forKey: .data))
        case .peerLeft:
            self = .peerLeft(try container.decode(PeerLeftData.self, forKey: .data))
        case .relayed:
            self = .relayed(try container.decode(RelayedData.self, forKey: .data))
        case .invitationCreated:
            self = .invitationCreated(try container.decode(InvitationCreatedData.self, forKey: .data))
        case .joinRequestForHost:
            self = .joinRequestForHost(try container.decode(JoinRequestForHostData.self, forKey: .data))
        case .sessionResumed:
            self = .sessionResumed(try container.decode(SessionResumedData.self, forKey: .data))
        case .error:
            self = .error(try container.decode(ErrorData.self, forKey: .data))
        case .kicked:
            self = .kicked(try container.decode(KickedData.self, forKey: .data))
        case .heartbeatPong:
            self = .heartbeatPong(try container.decode(HeartbeatPongData.self, forKey: .data))
        case .claimSuccess:
            self = .claimSuccess(try container.decode(ClaimSuccessData.self, forKey: .data))
        case .claimRejected:
            self = .claimRejected(try container.decode(ClaimRejectedData.self, forKey: .data))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .hostAuth(let data):
            try container.encode(FrameType.hostAuth, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .joinRequest(let data):
            try container.encode(FrameType.joinRequest, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .forward(let data):
            try container.encode(FrameType.forward, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .kickPeer(let data):
            try container.encode(FrameType.kickPeer, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .createInvitation(let data):
            try container.encode(FrameType.createInvitation, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .revokeInvitation(let data):
            try container.encode(FrameType.revokeInvitation, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .joinApproval(let data):
            try container.encode(FrameType.joinApproval, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .ack(let data):
            try container.encode(FrameType.ack, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .closePool(let data):
            try container.encode(FrameType.closePool, forKey: .frameType)
            if let data = data {
                try container.encode(data, forKey: .data)
            }
        case .handshakeInit(let data):
            try container.encode(FrameType.handshakeInit, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .heartbeatPing(let data):
            try container.encode(FrameType.heartbeatPing, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .claimServer(let data):
            try container.encode(FrameType.claimServer, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .serverHello(let data):
            try container.encode(FrameType.serverHello, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .hostAuthSuccess(let data):
            try container.encode(FrameType.hostAuthSuccess, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .joinAccepted(let data):
            try container.encode(FrameType.joinAccepted, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .joinRejected(let data):
            try container.encode(FrameType.joinRejected, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .peerJoined(let data):
            try container.encode(FrameType.peerJoined, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .peerLeft(let data):
            try container.encode(FrameType.peerLeft, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .relayed(let data):
            try container.encode(FrameType.relayed, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .invitationCreated(let data):
            try container.encode(FrameType.invitationCreated, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .joinRequestForHost(let data):
            try container.encode(FrameType.joinRequestForHost, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .sessionResumed(let data):
            try container.encode(FrameType.sessionResumed, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .error(let data):
            try container.encode(FrameType.error, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .kicked(let data):
            try container.encode(FrameType.kicked, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .heartbeatPong(let data):
            try container.encode(FrameType.heartbeatPong, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .claimSuccess(let data):
            try container.encode(FrameType.claimSuccess, forKey: .frameType)
            try container.encode(data, forKey: .data)
        case .claimRejected(let data):
            try container.encode(FrameType.claimRejected, forKey: .frameType)
            try container.encode(data, forKey: .data)
        }
    }
}

// MARK: - Convenience Encoding/Decoding

extension ServerFrame {

    /// Shared encoder configured for snake_case JSON output.
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Shared decoder configured for snake_case JSON input.
    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    /// Encode this frame to JSON data for transmission over WebSocket.
    ///
    /// - Returns: The JSON-encoded frame data.
    /// - Throws: ``EncodingError`` if encoding fails.
    public func toJSON() throws -> Data {
        try Self.jsonEncoder.encode(self)
    }

    /// Decode a frame from JSON data received over WebSocket.
    ///
    /// - Parameter data: The JSON data to decode.
    /// - Returns: The decoded ``ServerFrame``.
    /// - Throws: ``DecodingError`` if the data does not represent a valid frame.
    public static func fromJSON(_ data: Data) throws -> ServerFrame {
        try jsonDecoder.decode(ServerFrame.self, from: data)
    }
}
