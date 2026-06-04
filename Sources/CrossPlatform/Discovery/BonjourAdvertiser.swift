// BonjourAdvertiser.swift
// ConnectionPool / CrossPlatform / Discovery
//
// `_chessup-pvp._tcp` mDNS advertiser using Apple's `Network.framework`
// `NWListener`. Listens on an ephemeral TCP port and registers a Bonjour
// service with the spec-§2.2 TXT keys. Hand each accepted `NWConnection` to
// the consumer via the `onConnection` callback so they can wrap it in a
// `SocketConnection` and pass it to `CrossPlatformPool.acceptGuest(...)`.
//
// `_chessup-pvp._tcp` is disjoint from the legacy MC service
// `_stealthos-pool._tcp/_udp`, so this advertiser coexists peacefully with
// the existing MultipeerConnectivity transport in the same process.

import Foundation
import Network

public final class BonjourAdvertiser: @unchecked Sendable {

    public static let serviceType: String = "_chessup-pvp._tcp"
    public static let domain: String = "local."

    public struct TXTKeys {
        public static let version: String = "v"
        public static let name: String = "name"
        public static let host: String = "host"
        public static let pid: String = "pid"
        public static let poolCode: String = "pc"
        public static let capability: String = "cap"
        public static let platform: String = "plat"
        /// Pairing mode advertised by the host. Spec v1.6 §2.2:
        ///   - `"tap"`  → guest types the 6-digit tap code (legacy default).
        ///   - `"hotspot"` → host is running a private Wi-Fi hotspot; guest
        ///     joins the SSID, then auto-handshakes with the constant PSK
        ///     seed `"HOTSPOT"`.
        /// Absent → treat as `"tap"` (pre-v1.6 hosts).
        public static let mode: String = "mode"
    }

    /// Constant PSK seed for hotspot-mode pairings. Spec v1.6 §4.2.1.
    /// Verbatim 7 ASCII bytes. MUST match the Kotlin reference
    /// `HotspotPsk.HOTSPOT_PSK_SEED` byte-for-byte — a unilateral change
    /// on either platform is a wire-incompatible break.
    public static let hotspotPSKSeed: String = "HOTSPOT"

    public let poolName: String
    public let hostDisplayName: String
    public let pidB64u: String
    public let hasPoolCode: Bool
    public let capability: String

    private let listener: NWListener
    private let queue: DispatchQueue
    private var onConnection: (@Sendable (NWConnection) -> Void)?

    public init(
        poolName: String,
        hostDisplayName: String,
        localPID: Data,
        hasPoolCode: Bool = false,
        capability: String = CrossPlatformHandshake.capChess1,
        port: NWEndpoint.Port = .any,
        queue: DispatchQueue = DispatchQueue(label: "ConnectionPool.BonjourAdvertiser")
    ) throws {
        precondition(localPID.count == 16, "localPID must be 16 bytes")
        self.poolName = poolName
        self.hostDisplayName = hostDisplayName
        self.pidB64u = CrossPlatformBase64.encode16(localPID)
        self.hasPoolCode = hasPoolCode
        self.capability = capability
        self.queue = queue

        // TCP keepalive on accepted connections so a peer that walks
        // out of Wi-Fi range without a clean RST is detected by the
        // kernel within ~60 s (30 s idle + 3 × 10 s probes) rather than
        // never. Apple's default `NWParameters.tcp` leaves keepalive
        // off; even with it on the default idle window is 2 hours,
        // which is wrong for a game session expected to last minutes.
        // Listener parameters propagate to every accepted NWConnection.
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveInterval = 10
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        // Apple recommends enabling peer-to-peer reachability on local Wi-Fi.
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters, on: port)
        listener.service = NWListener.Service(
            name: poolName,
            type: BonjourAdvertiser.serviceType,
            domain: BonjourAdvertiser.domain,
            txtRecord: BonjourAdvertiser.makeTXTRecord(
                version: "1",
                name: poolName,
                host: hostDisplayName,
                pidB64u: CrossPlatformBase64.encode16(localPID),
                hasPoolCode: hasPoolCode,
                capability: capability
            )
        )
        self.listener = listener
    }

    public func start(onConnection: @escaping @Sendable (NWConnection) -> Void) {
        self.onConnection = onConnection
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else {
                conn.cancel()
                return
            }
            self.onConnection?(conn)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener.cancel()
    }

    /// The actual bound port. `nil` until `start` is called and the OS picks
    /// an ephemeral port.
    public var port: NWEndpoint.Port? { listener.port }

    /// Build a TXT record per spec §2.2. Each entry is encoded as a
    /// `Data` UTF-8 string; `NWTXTRecord` handles the wire encoding.
    public static func makeTXTRecord(
        version: String,
        name: String,
        host: String,
        pidB64u: String,
        hasPoolCode: Bool,
        capability: String,
        platform: String? = "ios"
    ) -> NWTXTRecord {
        var record = NWTXTRecord()
        record[TXTKeys.version] = version
        record[TXTKeys.name] = name
        record[TXTKeys.host] = host
        record[TXTKeys.pid] = pidB64u
        record[TXTKeys.poolCode] = hasPoolCode ? "1" : "0"
        record[TXTKeys.capability] = capability
        if let platform { record[TXTKeys.platform] = platform }
        return record
    }
}
