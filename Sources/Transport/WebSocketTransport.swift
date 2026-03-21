// WebSocketTransport.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import CryptoKit
import Combine
import Security

// MARK: - Pinned Session Delegate

/// URLSession delegate that performs SPKI (Subject Public Key Info) SHA-256 pin verification
/// on TLS connections. When a pin hash is configured, only servers whose leaf certificate's
/// SPKI matches the expected hash are accepted. When no pin is configured (e.g., local/dev mode),
/// standard system CA validation is used as a fallback.
final class PinnedSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    /// The expected SHA-256 hash of the server's leaf certificate SPKI, as raw bytes.
    /// When `nil`, standard CA validation applies (no pinning).
    private let expectedSPKIHash: Data?

    /// Creates a pinned session delegate.
    ///
    /// - Parameter expectedSPKIHash: SHA-256 hash of the expected server SPKI, or `nil` to
    ///   fall back to standard system TLS validation.
    init(expectedSPKIHash: Data? = nil) {
        self.expectedSPKIHash = expectedSPKIHash
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // If no pin is configured, fall back to standard CA validation.
        guard let expectedHash = expectedSPKIHash else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Evaluate the trust chain first using system CAs.
        var cfError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &cfError) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Extract the leaf certificate and its public key SPKI.
        guard SecTrustGetCertificateCount(serverTrust) > 0,
              let leafCert = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
              let certificate = leafCert.first,
              let publicKey = SecCertificateCopyKey(certificate),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // SHA-256 hash the SPKI data and compare against the expected pin.
        let spkiHash = Data(SHA256.hash(data: publicKeyData))

        if spkiHash == expectedHash {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - WebSocket Transport

/// A ``TransportProvider`` implementation that communicates with the StealthRelay server
/// over a WebSocket connection using ``URLSessionWebSocketTask``.
///
/// This transport handles:
/// - Host authentication via Ed25519-signed ``HostAuth`` frames
/// - Client join requests using invitation tokens
/// - Heartbeat ping/pong to keep the connection alive
/// - Exponential backoff reconnection on disconnection
/// - Translation of ``ServerFrame`` events into ``TransportDelegate`` callbacks
///
/// All state mutations and delegate callbacks occur on the MainActor.
@MainActor
public final class WebSocketTransport: NSObject, TransportProvider, @unchecked Sendable {

    // MARK: - Public Properties

    /// The unique identifier for this peer, assigned by the server after authentication.
    public private(set) var localPeerID: String

    /// The human-readable display name of the local peer.
    public let localPeerName: String

    /// The current state of the WebSocket transport.
    @Published public private(set) var state: TransportState = .idle

    /// The delegate that receives transport lifecycle and data events.
    public weak var delegate: (any TransportDelegate)?

    // MARK: - Configuration

    /// The remote pool configuration.
    private let configuration: RemotePoolConfiguration

    // MARK: - WebSocket State

    /// The URLSession used for WebSocket connections.
    private var urlSession: URLSession?

    /// The active WebSocket task.
    private var webSocketTask: URLSessionWebSocketTask?

    /// Session token received from the server for reconnection.
    private(set) var sessionToken: String?

    /// Monotonically increasing sequence number for outgoing messages.
    private var sequenceNumber: UInt64 = 0

    /// Connected peers tracked by peer ID.
    private var connectedPeers: [String: TransportPeer] = [:]

    /// Pool info received after joining.
    private var currentPoolInfo: ServerPoolInfo?

    // MARK: - Host State

    /// The host identity used for authentication (only set when hosting).
    private var hostIdentity: RemoteHostIdentity?

    /// The pool ID being hosted or joined.
    private var poolID: UUID?

    /// Pending join requests keyed by client public key, awaiting host approval.
    private var pendingJoinRequests: [String: JoinRequestForHostData] = [:]

    // MARK: - Client State

    /// Parsed invitation for joining a pool.
    private var joinInvitation: ParsedInvitation?

    /// Tracks whether a PoW retry is in progress to prevent infinite loops.
    private var powRetryInProgress = false

    // MARK: - Heartbeat

    /// Task managing the heartbeat ping loop.
    private var heartbeatTask: Task<Void, Never>?

    /// Timestamp of the last received pong, for idle detection.
    private var lastPongTimestamp: Date?

    // MARK: - Reconnection

    /// Current reconnection attempt count.
    private var reconnectAttempt: Int = 0

    /// Task managing the reconnection delay.
    private var reconnectTask: Task<Void, Never>?

    /// Whether the transport was intentionally disconnected (suppresses reconnection).
    private var intentionalDisconnect: Bool = false

    /// The role of this transport (host or client) for reconnection context.
    private var isHostRole: Bool = false

    // MARK: - Receive Loop

    /// Task managing the WebSocket receive loop.
    private var receiveTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a new WebSocket transport.
    ///
    /// - Parameters:
    ///   - configuration: The remote pool configuration with server URL and settings.
    ///   - displayName: The display name for the local peer.
    ///   - peerID: Optional pre-assigned peer ID (used during reconnection).
    public init(
        configuration: RemotePoolConfiguration,
        displayName: String,
        peerID: String? = nil
    ) {
        self.configuration = configuration
        self.localPeerName = displayName
        self.localPeerID = peerID ?? UUID().uuidString
        super.init()
    }

    deinit {
        heartbeatTask?.cancel()
        reconnectTask?.cancel()
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - TransportProvider: Host Operations

    /// Begin advertising a pool by connecting to the relay server and authenticating as host.
    ///
    /// - Parameter poolInfo: Metadata about the pool being advertised.
    public func startAdvertising(poolInfo: PoolAdvertisementInfo) {
        guard state == .idle || state == .failed(.connectionFailed) else { return }

        isHostRole = true
        poolID = poolInfo.poolID
        intentionalDisconnect = false

        connect { [weak self] in
            guard let self else { return }
            self.sendHostAuth(poolInfo: poolInfo)
        }
    }

    /// Stop advertising the pool.
    public func stopAdvertising() {
        sendFrame(.closePool())
        disconnect()
    }

    /// Accept a pending join request from a peer.
    ///
    /// - Parameter peerID: The public key identifier of the requesting peer.
    public func acceptConnection(from peerID: String) {
        sendFrame(.joinApproval(JoinApprovalData(
            clientPublicKey: peerID,
            approved: true
        )))
        pendingJoinRequests.removeValue(forKey: peerID)
    }

    /// Reject a pending join request from a peer.
    ///
    /// - Parameter peerID: The public key identifier of the requesting peer.
    public func rejectConnection(from peerID: String) {
        sendFrame(.joinApproval(JoinApprovalData(
            clientPublicKey: peerID,
            approved: false,
            reason: "Rejected by host"
        )))
        pendingJoinRequests.removeValue(forKey: peerID)
    }

    /// Kick a connected peer from the pool.
    ///
    /// - Parameter peerID: The identifier of the peer to disconnect.
    public func disconnectPeer(_ peerID: String) {
        sendFrame(.kickPeer(KickPeerData(
            peerId: peerID,
            reason: "Removed by host"
        )))
    }

    // MARK: - TransportProvider: Client Operations

    /// Begin discovery. For WebSocket transport, this is a no-op since remote pools
    /// are joined via invitation URL rather than mDNS discovery.
    public func startDiscovery() {
        updateState(.discovering)
    }

    /// Stop discovery.
    public func stopDiscovery() {
        if state == .discovering {
            updateState(.idle)
        }
    }

    /// Request to join a pool using an invitation.
    ///
    /// The ``JoinContext`` must contain the pool code which is used as the invitation token.
    /// For remote joins, use ``requestJoinWithInvitation(_:)`` for full invitation-based joining.
    ///
    /// - Parameters:
    ///   - poolID: The pool identifier to join.
    ///   - context: Join context containing the pool code / invitation data.
    public func requestJoin(poolID: String, context: JoinContext) {
        // For the generic TransportProvider interface, we use the pool code as a token hint.
        // Full remote joining should use requestJoinWithInvitation(_:) directly.
        isHostRole = false
        intentionalDisconnect = false
        self.poolID = UUID(uuidString: poolID)

        connect { [weak self] in
            guard let self else { return }
            self.updateState(.connecting)
        }
    }

    /// Request to join a pool using a parsed invitation.
    ///
    /// This is the primary entry point for joining a remote pool. The invitation contains
    /// the server URL, pool ID, token secret, and host fingerprint needed for authentication.
    ///
    /// - Parameter invitation: The parsed invitation from a URL or QR code.
    public func requestJoinWithInvitation(_ invitation: ParsedInvitation) {
        isHostRole = false
        intentionalDisconnect = false
        joinInvitation = invitation
        poolID = invitation.poolId

        connect { [weak self] in
            guard let self else { return }
            self.sendJoinRequest(invitation: invitation)
        }
    }

    // MARK: - TransportProvider: Data Transmission

    /// Broadcast data to all connected peers via the relay server.
    ///
    /// - Parameters:
    ///   - data: The data to broadcast.
    ///   - reliable: Ignored for WebSocket (always reliable/ordered).
    public func broadcast(_ data: Data, reliable: Bool) {
        let base64 = data.base64EncodedString()
        let seq = nextSequence()
        sendFrame(.forward(ForwardData(data: base64, targetPeerIds: nil, sequence: seq)))
    }

    /// Send data to specific peers via the relay server.
    ///
    /// - Parameters:
    ///   - data: The data to send.
    ///   - peerIDs: The identifiers of the target peers.
    ///   - reliable: Ignored for WebSocket (always reliable/ordered).
    public func send(_ data: Data, to peerIDs: [String], reliable: Bool) {
        guard !peerIDs.isEmpty else { return }
        let base64 = data.base64EncodedString()
        let seq = nextSequence()
        sendFrame(.forward(ForwardData(data: base64, targetPeerIds: peerIDs, sequence: seq)))
    }

    // MARK: - TransportProvider: Lifecycle

    /// Disconnect from the relay server and clean up all resources.
    public func disconnect() {
        intentionalDisconnect = true
        tearDown()
        updateState(.idle)
    }

    // MARK: - Server Claim

    /// Claim an unclaimed server by providing the claim code from the server's Docker logs.
    ///
    /// The claim code can be in any of these formats:
    /// - Dash-separated: `ABCD-EF01-2345-6789-ABCD-EF01-2345`
    /// - Raw hex (64 chars): `abcdef0123456789...`
    /// - Full URL: `stealth://claim/<64_hex_chars>`
    ///
    /// This must be called before `startAdvertising` on a fresh, unclaimed server.
    ///
    /// - Parameter claimCode: The claim code in any supported format.
    public func claimServer(claimCode: String) {
        let rawHex = Self.normalizeClaimCode(claimCode)

        do {
            let identity = try RemotePoolService().getOrCreateHostIdentity()
            self.hostIdentity = identity

            let frame = ServerFrame.claimServer(ClaimServerData(
                claimSecret: rawHex,
                hostPublicKey: identity.publicKeyData.base64EncodedString(),
                displayName: localPeerName
            ))
            sendFrame(frame)
        } catch {
            logMessage("Failed to get host identity for claim: \(error.localizedDescription)")
            delegate?.transport(self, didFailWithError: .authenticationFailed)
        }
    }

    /// Normalize a claim code from any supported format into a raw hex string.
    ///
    /// Supported formats:
    /// - `stealth://claim/<hex>` URL
    /// - Dash-separated hex: `ABCD-EF01-...`
    /// - Raw hex string
    internal static func normalizeClaimCode(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle stealth://claim/<hex> URL format
        if trimmed.lowercased().hasPrefix("stealth://claim/") {
            let hex = String(trimmed.dropFirst("stealth://claim/".count))
            return hex.lowercased()
        }

        // Remove dashes for dash-separated format, then lowercase
        return trimmed.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - Internal: Connection Management

    /// Establish the WebSocket connection to the relay server.
    private func connect(onConnected: @escaping @Sendable @MainActor () -> Void) {
        updateState(.connecting)

        let url = configuration.serverURL
        logMessage("WebSocket connecting to \(url.host ?? "unknown"):\(url.port ?? 0)")

        // SECURITY: Use ephemeral configuration to avoid caching credentials,
        // cookies, or connection metadata to disk. A privacy-focused app must not
        // persist WebSocket connection artifacts.
        //
        // SECURITY: Attach PinnedSessionDelegate for SPKI certificate pinning when a
        // pin hash is configured. This prevents MITM attacks even if a rogue CA issues
        // a certificate for the relay server's domain.
        let pinDelegate = PinnedSessionDelegate(expectedSPKIHash: configuration.pinnedSPKIHash)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: pinDelegate,
            delegateQueue: nil
        )
        self.urlSession = session

        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        logMessage("WebSocket task resumed, state: \(task.state.rawValue)")

        // Start the receive loop for server responses.
        startReceiveLoop()

        // Send the first frame immediately — the server doesn't send anything
        // until the client authenticates. Don't wait for a server hello.
        onConnected()
    }

    /// Tear down the current connection without updating state.
    private func tearDown() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        connectedPeers.removeAll()
        pendingJoinRequests.removeAll()
        lastPongTimestamp = nil
    }

    /// Attempt to reconnect with exponential backoff.
    private func attemptReconnect() {
        guard !intentionalDisconnect else { return }

        reconnectAttempt += 1

        guard reconnectAttempt <= configuration.maxReconnectAttempts else {
            updateState(.failed(.connectionFailed))
            delegate?.transport(self, didFailWithError: .connectionFailed)
            return
        }

        updateState(.reconnecting(attempt: reconnectAttempt))

        let delay = min(
            configuration.initialReconnectDelay * pow(2.0, Double(reconnectAttempt - 1)),
            configuration.maxReconnectDelay
        )

        let attempt = reconnectAttempt
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }

            await MainActor.run {
                guard self.state == .reconnecting(attempt: attempt) else { return }
                self.tearDown()
                self.connect { [weak self] in
                    guard let self else { return }
                    if self.isHostRole, let poolID = self.poolID {
                        self.sendHostAuth(poolInfo: PoolAdvertisementInfo(
                            poolID: poolID,
                            poolName: self.configuration.poolName,
                            hostName: self.localPeerName,
                            maxPeers: self.configuration.maxPeers
                        ))
                    } else if let invitation = self.joinInvitation {
                        // SECURITY: Check invitation expiry before reconnecting.
                        // Reusing an expired invitation causes the server to reject
                        // every attempt, creating an infinite retry loop with battery drain.
                        guard !invitation.isExpired else {
                            self.logMessage("[SECURITY] Invitation expired during reconnection, stopping retry")
                            self.reconnectTask?.cancel()
                            self.reconnectTask = nil
                            self.intentionalDisconnect = true
                            self.updateState(.failed(.invalidToken))
                            self.delegate?.transport(self, didFailWithError: .invalidToken)
                            return
                        }
                        self.sendJoinRequest(invitation: invitation)
                    }
                }
            }
        }
    }

    // MARK: - Internal: Frame Sending

    /// Send a ``ServerFrame`` over the WebSocket connection.
    private func sendFrame(_ frame: ServerFrame) {
        guard let task = webSocketTask else {
            logMessage("sendFrame: webSocketTask is nil, dropping frame")
            return
        }

        // Inject session token into privileged host frames
        let frame = injectSessionToken(into: frame)

        do {
            let data = try frame.toJSON()
            let text = String(data: data, encoding: .utf8) ?? ""
            let message = URLSessionWebSocketTask.Message.string(text)
            task.send(message) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        self.logMessage("Send error: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            logMessage("Frame encoding error: \(error.localizedDescription)")
        }
    }

    /// Injects the stored session token into privileged host frames before sending.
    private func injectSessionToken(into frame: ServerFrame) -> ServerFrame {
        guard let token = sessionToken, isHostRole else { return frame }
        switch frame {
        case .createInvitation(var data):
            data.sessionToken = token
            return .createInvitation(data)
        case .forward(var data):
            data.sessionToken = token
            return .forward(data)
        case .kickPeer(var data):
            data.sessionToken = token
            return .kickPeer(data)
        case .revokeInvitation(var data):
            data.sessionToken = token
            return .revokeInvitation(data)
        case .joinApproval(var data):
            data.sessionToken = token
            return .joinApproval(data)
        case .closePool:
            return .closePool(ClosePoolData(sessionToken: token))
        default:
            return frame
        }
    }

    /// Send host authentication frame signed with the host identity.
    private func sendHostAuth(poolInfo: PoolAdvertisementInfo) {
        do {
            let identity = try RemotePoolService().getOrCreateHostIdentity()
            self.hostIdentity = identity

            let timestamp = Int64(Date().timeIntervalSince1970)

            // MUST match the Rust server's signature format:
            // "STEALTH_HOST_AUTH_V1:" || pool_id_raw_bytes (16) || timestamp_be (8)
            var signData = Data("STEALTH_HOST_AUTH_V1:".utf8)
            let uuid = poolInfo.poolID
            signData.append(contentsOf: withUnsafeBytes(of: uuid.uuid) { Data($0) })
            signData.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian) { Data($0) })

            let signature = try identity.sign(signData)

            let frame = ServerFrame.hostAuth(HostAuthData(
                hostPublicKey: identity.publicKeyData.base64EncodedString(),
                timestamp: timestamp,
                signature: signature.base64EncodedString(),
                poolId: poolInfo.poolID,
                serverUrl: configuration.serverURL.absoluteString,
                displayName: localPeerName
            ))
            sendFrame(frame)
        } catch {
            updateState(.failed(.authenticationFailed))
            delegate?.transport(self, didFailWithError: .authenticationFailed)
        }
    }

    /// Send a join request using a parsed invitation.
    ///
    /// SECURITY: Before using the invitation, we verify:
    /// 1. The invitation has not expired.
    /// 2. The host fingerprint is present and non-empty (integrity check).
    /// 3. The token secret is cryptographically bound to the host fingerprint via HKDF derivation,
    ///    ensuring a tampered fingerprint produces an invalid proof that the server will reject.
    private func sendJoinRequest(invitation: ParsedInvitation) {
        updateState(.connecting)

        // SECURITY: Reject expired invitations before sending anything to the server.
        guard !invitation.isExpired else {
            logMessage("[SECURITY] Invitation has expired, rejecting join request")
            updateState(.failed(.invalidToken))
            delegate?.transport(self, didFailWithError: .invalidToken)
            return
        }

        // SECURITY: Verify host fingerprint is present and non-empty.
        // The fingerprint is an 8-byte value embedded by the host during invitation creation.
        // An empty or missing fingerprint indicates a tampered or malformed invitation.
        guard !invitation.hostFingerprint.isEmpty else {
            logMessage("[SECURITY] Invitation has empty host fingerprint, rejecting")
            updateState(.failed(.authenticationFailed))
            delegate?.transport(self, didFailWithError: .authenticationFailed)
            return
        }

        let timestamp = Int64(Date().timeIntervalSince1970)
        var nonce = Data(count: 32)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        // Derive verification key: HKDF-SHA256(ikm=tokenSecret, salt=poolId, info="STEALTH_INVITE_V1" || tokenId)
        let poolIdBytes = withUnsafeBytes(of: invitation.poolId.uuid) { Data($0) }
        let symmetricSecret = SymmetricKey(data: invitation.tokenSecret)

        var info = Data("STEALTH_INVITE_V1".utf8)
        info.append(invitation.tokenId)

        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: symmetricSecret,
            salt: poolIdBytes,
            info: info,
            outputByteCount: 32
        )

        // Compute HMAC proof: HMAC-SHA256(key=vk, message="JOIN" || poolId || timestamp || nonce)
        let vkData = derivedKey.withUnsafeBytes { Data($0) }
        let hmacKey = SymmetricKey(data: vkData)
        var message = Data("JOIN".utf8)
        message.append(poolIdBytes)
        message.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian) { Data($0) })
        message.append(nonce)

        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: hmacKey)
        let proof = Data(hmac)

        // Generate a client keypair for this session
        let clientKey = Curve25519.Signing.PrivateKey()

        let frame = ServerFrame.joinRequest(JoinRequestData(
            tokenId: invitation.tokenId.base64EncodedString(),
            proof: proof.base64EncodedString(),
            timestamp: timestamp,
            nonce: nonce.base64EncodedString(),
            clientPublicKey: clientKey.publicKey.rawRepresentation.base64EncodedString(),
            displayName: localPeerName
        ))
        sendFrame(frame)
    }

    /// Send a join request with a solved PoW solution attached.
    private func sendJoinRequestWithPoW(invitation: ParsedInvitation, powSolution: PowSolutionData) {
        let timestamp = Int64(Date().timeIntervalSince1970)
        var nonce = Data(count: 32)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        let poolIdBytes = withUnsafeBytes(of: invitation.poolId.uuid) { Data($0) }
        let symmetricSecret = SymmetricKey(data: invitation.tokenSecret)

        var info = Data("STEALTH_INVITE_V1".utf8)
        info.append(invitation.tokenId)

        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: symmetricSecret,
            salt: poolIdBytes,
            info: info,
            outputByteCount: 32
        )

        let vkData = derivedKey.withUnsafeBytes { Data($0) }
        let hmacKey = SymmetricKey(data: vkData)
        var message = Data("JOIN".utf8)
        message.append(poolIdBytes)
        message.append(contentsOf: withUnsafeBytes(of: timestamp.bigEndian) { Data($0) })
        message.append(nonce)

        let hmac = HMAC<SHA256>.authenticationCode(for: message, using: hmacKey)
        let proof = Data(hmac)

        let clientKey = Curve25519.Signing.PrivateKey()

        let frame = ServerFrame.joinRequest(JoinRequestData(
            tokenId: invitation.tokenId.base64EncodedString(),
            proof: proof.base64EncodedString(),
            timestamp: timestamp,
            nonce: nonce.base64EncodedString(),
            clientPublicKey: clientKey.publicKey.rawRepresentation.base64EncodedString(),
            displayName: localPeerName,
            powSolution: powSolution
        ))
        sendFrame(frame)
    }

    // MARK: - Proof-of-Work Solver

    /// Parsed PoW challenge extracted from a server error message.
    private struct ParsedPowChallenge {
        let challengeBytes: Data
        let challengeBase64: String
        let difficulty: UInt8
    }

    /// Parse a PoW challenge from the server's error message.
    /// Format: "proof-of-work required: {"challenge":"<base64>","difficulty":<n>,"timestamp":<t>}"
    nonisolated private static func parsePowChallenge(from message: String) -> ParsedPowChallenge? {
        guard let jsonStart = message.range(of: "{") else { return nil }
        let jsonString = String(message[jsonStart.lowerBound...])
        guard let jsonData = jsonString.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(PowChallengeData.self, from: jsonData),
              let challengeBytes = Data(base64Encoded: parsed.challenge) else {
            return nil
        }
        return ParsedPowChallenge(
            challengeBytes: challengeBytes,
            challengeBase64: parsed.challenge,
            difficulty: parsed.difficulty
        )
    }

    /// Solve a PoW challenge by brute-force SHA-256 search.
    /// Finds a nonce such that SHA-256("STEALTH_POW" || challenge || nonce) has `difficulty` leading zero bits.
    /// This is CPU-intensive — call from a background thread.
    nonisolated private static func solvePoW(challenge: Data, difficulty: UInt8) -> [UInt8] {
        let prefix = Data("STEALTH_POW".utf8)
        var nonce: UInt64 = 0

        while true {
            let nonceBytes = withUnsafeBytes(of: nonce.bigEndian) { Data($0) }
            var input = prefix
            input.append(challenge)
            input.append(nonceBytes)

            let hash = SHA256.hash(data: input)
            if Self.leadingZeroBits(Array(hash)) >= UInt32(difficulty) {
                return Array(nonceBytes)
            }
            nonce &+= 1
        }
    }

    /// Count leading zero bits in a byte array.
    nonisolated private static func leadingZeroBits(_ bytes: [UInt8]) -> UInt32 {
        var count: UInt32 = 0
        for byte in bytes {
            if byte == 0 {
                count += 8
            } else {
                count += UInt32(byte.leadingZeroBitCount)
                break
            }
        }
        return count
    }

    // MARK: - Internal: Receive Loop

    /// Start the WebSocket receive loop.
    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let task = await MainActor.run(body: { self.webSocketTask }) else { break }

                do {
                    let message = try await task.receive()
                    guard !Task.isCancelled else { break }

                    await MainActor.run {
                        let data: Data
                        switch message {
                        case .data(let d):
                            data = d
                        case .string(let s):
                            data = Data(s.utf8)
                        @unknown default:
                            return
                        }

                        do {
                            let frame = try ServerFrame.fromJSON(data)
                            self.handleFrame(frame)
                        } catch {
                            self.logMessage("Frame decode error: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        self.handleConnectionLost(error: error)
                    }
                    break
                }
            }
        }
    }

    // MARK: - Internal: Frame Handling

    /// Handle a received ``ServerFrame`` from the server.
    private func handleFrame(_ frame: ServerFrame) {
        switch frame {
        case .serverHello:
            // Server hello received; connection is established.
            // Server hello is informational; auth is sent in connect().
            break

        case .hostAuthSuccess(let data):
            sessionToken = data.sessionToken
            poolID = data.poolId
            // Set localPeerID to match what the server uses (base64 public key).
            // This ensures key exchange, message routing, and peer identity all align.
            if let identity = hostIdentity {
                localPeerID = identity.publicKeyData.base64EncodedString()
            }
            reconnectAttempt = 0
            updateState(.advertising)
            startHeartbeat()

        case .joinAccepted(let data):
            sessionToken = data.sessionToken
            localPeerID = data.peerId
            currentPoolInfo = data.poolInfo
            reconnectAttempt = 0
            updateState(.connected)
            startHeartbeat()

            // Register existing peers
            for peerInfo in data.peers {
                let peer = TransportPeer(
                    id: peerInfo.peerId,
                    displayName: peerInfo.displayName,
                    connectionType: .relayed,
                    publicKey: peerInfo.publicKey,
                    connectedAt: Date(timeIntervalSince1970: TimeInterval(peerInfo.connectedAt))
                )
                connectedPeers[peerInfo.peerId] = peer
                delegate?.transport(self, peerDidConnect: peer)
            }

        case .joinRejected(let data):
            updateState(.failed(.authenticationFailed))
            logMessage("Join rejected: \(data.reason)")
            delegate?.transport(self, didFailWithError: .authenticationFailed)

        case .peerJoined(let data):
            let peer = TransportPeer(
                id: data.peer.peerId,
                displayName: data.peer.displayName,
                connectionType: .relayed,
                publicKey: data.peer.publicKey,
                connectedAt: Date(timeIntervalSince1970: TimeInterval(data.peer.connectedAt))
            )
            connectedPeers[data.peer.peerId] = peer
            delegate?.transport(self, peerDidConnect: peer)

        case .peerLeft(let data):
            connectedPeers.removeValue(forKey: data.peerId)
            delegate?.transport(self, peerDidDisconnect: data.peerId)

        case .relayed(let data):
            // Decode base64 data and deliver to delegate
            if let rawData = Data(base64Encoded: data.data) {
                delegate?.transport(self, didReceiveData: rawData, from: data.fromPeerId)
            }
            // Acknowledge receipt
            sendFrame(.ack(AckData(sequence: data.sequence)))

        case .invitationCreated(let data):
            deliverInvitationCreated(data)

        case .joinRequestForHost(let data):
            // Store the pending request and notify the delegate
            pendingJoinRequests[data.clientPublicKey] = data
            delegate?.transport(
                self,
                didReceiveJoinRequest: data.clientPublicKey,
                displayName: data.displayName,
                context: JoinContext(poolCode: data.tokenId)
            )

        case .sessionResumed(let data):
            reconnectAttempt = 0
            // Process any missed messages
            for missedFrame in data.missedMessages {
                handleFrame(missedFrame)
            }
            if isHostRole {
                updateState(.advertising)
            } else {
                updateState(.connected)
            }

        case .error(let data):
            logMessage("Server error [\(data.code)]: \(data.message)")

            // Handle PoW challenge (HTTP 428): solve and resubmit join request
            if data.code == 428, !powRetryInProgress, let invitation = joinInvitation {
                logMessage("PoW challenge received, solving...")
                powRetryInProgress = true
                if let challenge = Self.parsePowChallenge(from: data.message) {
                    let challengeBytes = challenge.challengeBytes
                    let challengeBase64 = challenge.challengeBase64
                    let difficulty = challenge.difficulty
                    Task.detached(priority: .userInitiated) {
                        let solution = WebSocketTransport.solvePoW(challenge: challengeBytes, difficulty: difficulty)
                        let solutionData = PowSolutionData(
                            challenge: challengeBase64,
                            solution: Data(solution).base64EncodedString()
                        )
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.logMessage("PoW solved, resubmitting join request")
                            self.sendJoinRequestWithPoW(invitation: invitation, powSolution: solutionData)
                            self.powRetryInProgress = false
                        }
                    }
                } else {
                    powRetryInProgress = false
                    delegate?.transport(self, didFailWithError: .from(NSError(domain: "ServerFrame", code: 428,
                                                                              userInfo: [NSLocalizedDescriptionKey: "Failed to parse PoW challenge"])))
                }
                return
            }

            let transportError: TransportError
            let lowerMessage = data.message.lowercased()
            if lowerMessage.contains("not yet claimed") || lowerMessage.contains("unclaimed") || lowerMessage.contains("not claimed") {
                transportError = .serverUnclaimed
            } else {
                switch data.code {
                case 401: transportError = .authenticationFailed
                case 403: transportError = .invalidToken
                case 408: transportError = .timeout
                case 410: transportError = .sessionExpired
                case 426: transportError = .protocolMismatch
                default: transportError = .from(NSError(domain: "ServerFrame", code: Int(data.code),
                                                         userInfo: [NSLocalizedDescriptionKey: data.message]))
                }
            }
            delegate?.transport(self, didFailWithError: transportError)

        case .kicked(let data):
            logMessage("Kicked from pool: \(data.reason)")
            intentionalDisconnect = true
            tearDown()
            updateState(.failed(.kicked))
            delegate?.transport(self, didFailWithError: .kicked)

        case .heartbeatPong(let data):
            lastPongTimestamp = Date()
            _ = data.serverTime // Available for clock sync if needed

        case .claimSuccess(let data):
            logMessage("Server claimed successfully (fingerprint: \(data.serverFingerprint.prefix(8))...)")
            // Deliver the claim success via the one-shot continuation if set.
            deliverClaimSuccess(data)
            // Also notify delegate that the connection is ready for HostAuth.
            delegate?.transport(self, didChangeState: .idle)

        case .claimRejected(let data):
            logMessage("Server claim rejected: \(data.reason)")
            delegate?.transport(self, didFailWithError: .authenticationFailed)

        case .hostAuth, .joinRequest, .forward, .kickPeer,
             .createInvitation, .revokeInvitation, .joinApproval,
             .ack, .closePool, .handshakeInit, .heartbeatPing,
             .claimServer:
            // These are client-to-server frames; should not be received from server.
            logMessage("Unexpected client->server frame received from server")
        }
    }

    /// Handle a WebSocket connection loss.
    private func handleConnectionLost(error: Error) {
        logMessage("Connection lost: \(error.localizedDescription)")
        tearDown()

        if !intentionalDisconnect {
            attemptReconnect()
        }
    }

    // MARK: - Internal: Heartbeat

    /// Start the periodic heartbeat ping loop.
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        lastPongTimestamp = Date()

        heartbeatTask = Task { [weak self, interval = configuration.heartbeatInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    guard let self else { return }

                    // Check for idle timeout (3x heartbeat interval without pong)
                    if let lastPong = self.lastPongTimestamp,
                       Date().timeIntervalSince(lastPong) > interval * 3 {
                        self.logMessage("Heartbeat timeout - no pong received")
                        self.handleConnectionLost(
                            error: NSError(domain: "WebSocketTransport", code: -1,
                                           userInfo: [NSLocalizedDescriptionKey: "Heartbeat timeout"])
                        )
                        return
                    }

                    let timestamp = Int64(Date().timeIntervalSince1970)
                    self.sendFrame(.heartbeatPing(HeartbeatPingData(timestamp: timestamp)))
                }
            }
        }
    }

    // MARK: - Internal: Helpers

    /// Generate the next sequence number.
    private func nextSequence() -> UInt64 {
        sequenceNumber += 1
        return sequenceNumber
    }

    /// Update the transport state and notify the delegate.
    private func updateState(_ newState: TransportState) {
        state = newState
        delegate?.transport(self, didChangeState: newState)
    }

    /// Log a message using the ConnectionPool package-level logger.
    private func logMessage(_ message: String) {
        log("WebSocketTransport: \(message)", level: .info, category: .network)
    }

    // MARK: - Invitation Frame Listener

    /// Send HostAuth on the existing WebSocket connection after a successful claim.
    ///
    /// Unlike `startAdvertising`, this does not create a new connection — it reuses the
    /// current WebSocket that was used for the claim handshake.
    ///
    /// - Parameter poolInfo: Metadata about the pool being advertised.
    public func sendHostAuthAfterClaim(poolInfo: PoolAdvertisementInfo) {
        isHostRole = true
        poolID = poolInfo.poolID
        intentionalDisconnect = false
        sendHostAuth(poolInfo: poolInfo)
    }

    /// Send a CreateInvitation frame to the server.
    public func sendCreateInvitation(maxUses: UInt8, expiresInSecs: UInt64) {
        sendFrame(.createInvitation(CreateInvitationData(
            maxUses: maxUses,
            expiresInSecs: expiresInSecs
        )))
    }

    // MARK: - Claim Frame Listener

    /// One-shot continuation for claim success responses.
    /// @MainActor-isolated: only accessed from MainActor context (frame handler and waitFor methods).
    private var _claimContinuation: (@MainActor (ClaimSuccessData) -> Void)?

    /// Deliver a ``ClaimSuccess`` frame to the waiting continuation, if any.
    internal func deliverClaimSuccess(_ data: ClaimSuccessData) {
        let handler = _claimContinuation
        _claimContinuation = nil
        handler?(data)
    }

    /// One-shot continuation for invitation creation responses.
    /// @MainActor-isolated: only accessed from MainActor context (frame handler and waitFor methods).
    private var _invitationContinuation: (@MainActor (InvitationCreatedData) -> Void)?

    /// Wait for an ``InvitationCreated`` frame from the server.
    ///
    /// Used by ``RemotePoolService`` to asynchronously receive the invitation response
    /// after sending a ``CreateInvitation`` request.
    ///
    /// - Parameter timeout: Maximum time to wait for the response.
    /// - Returns: The invitation data, or nil if timed out.
    public func waitForInvitationCreated(timeout: TimeInterval = 10) async -> InvitationCreatedData? {
        await withCheckedContinuation { continuation in
            var resolved = false

            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !resolved {
                    resolved = true
                    self._invitationContinuation = nil
                    continuation.resume(returning: nil)
                }
            }

            // Install a one-shot frame interceptor.
            // Both this closure and the timeout run on @MainActor, so there is no data race
            // on `resolved` — only one will execute first, and the other will see it as true.
            self._invitationContinuation = { @MainActor [weak self] data in
                if !resolved {
                    resolved = true
                    timeoutTask.cancel()
                    self?._invitationContinuation = nil
                    continuation.resume(returning: data)
                }
            }
        }
    }

    /// Deliver an ``InvitationCreated`` frame to the waiting continuation, if any.
    internal func deliverInvitationCreated(_ data: InvitationCreatedData) {
        let handler = _invitationContinuation
        _invitationContinuation = nil
        handler?(data)
    }
}
