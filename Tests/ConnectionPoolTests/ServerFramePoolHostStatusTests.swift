// ServerFramePoolHostStatusTests.swift
// ConnectionPoolTests
//
// Wire-contract tests for the relay v0.5.0 `pool_host_status` frame and the
// `host_online` field on `ServerPoolInfo`. The Rust relay agent must produce
// JSON that decodes into the exact same Swift values asserted here — any
// deviation between the two sides is a wire-contract break.

import XCTest
@testable import ConnectionPool

final class ServerFramePoolHostStatusTests: XCTestCase {

    // MARK: - pool_host_status frame round-trips

    func testPoolHostStatusRoundTripOnline() throws {
        let frame: ServerFrame = .poolHostStatus(PoolHostStatusData(online: true))
        let data = try frame.toJSON()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"frame_type\":\"pool_host_status\""), json)
        XCTAssertTrue(json.contains("\"online\":true"), json)
        // `offline_since` is encoded with `encodeIfPresent` and must be omitted when nil.
        XCTAssertFalse(json.contains("offline_since"), "offline_since must be omitted when host is online: \(json)")

        let decoded = try ServerFrame.fromJSON(data)
        XCTAssertEqual(frame, decoded)
    }

    func testPoolHostStatusRoundTripOffline() throws {
        let timestamp: Int64 = 1714752345
        let frame: ServerFrame = .poolHostStatus(PoolHostStatusData(online: false, offlineSince: timestamp))
        let data = try frame.toJSON()
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"online\":false"), json)
        XCTAssertTrue(json.contains("\"offline_since\":\(timestamp)"), json)

        let decoded = try ServerFrame.fromJSON(data)
        XCTAssertEqual(frame, decoded)
        guard case .poolHostStatus(let payload) = decoded else {
            return XCTFail("expected .poolHostStatus, got \(decoded)")
        }
        XCTAssertFalse(payload.online)
        XCTAssertEqual(payload.offlineSince, timestamp)
    }

    func testPoolHostStatusDecodeFromRustWireFormat() throws {
        // Verbatim JSON the Rust relay agent will emit (per the wire contract spec).
        let wire = """
        {
          "frame_type": "pool_host_status",
          "data": {
            "online": false,
            "offline_since": 1714752345
          }
        }
        """
        let frame = try ServerFrame.fromJSON(wire.data(using: .utf8)!)
        guard case .poolHostStatus(let payload) = frame else {
            return XCTFail("expected .poolHostStatus, got \(frame)")
        }
        XCTAssertFalse(payload.online)
        XCTAssertEqual(payload.offlineSince, 1714752345)
    }

    func testPoolHostStatusOnlineWireFormatOmitsOfflineSince() throws {
        // When the relay flips the host back online it MAY omit `offline_since`.
        let wire = """
        {
          "frame_type": "pool_host_status",
          "data": { "online": true }
        }
        """
        let frame = try ServerFrame.fromJSON(wire.data(using: .utf8)!)
        guard case .poolHostStatus(let payload) = frame else {
            return XCTFail("expected .poolHostStatus, got \(frame)")
        }
        XCTAssertTrue(payload.online)
        XCTAssertNil(payload.offlineSince)
    }

    // MARK: - ServerPoolInfo.host_online compatibility

    func testServerPoolInfoDecodesWithHostOnlineFalse() throws {
        let json = """
        {
          "pool_id": "33333333-3333-3333-3333-333333333333",
          "name": "test",
          "host_peer_id": "peer1",
          "max_peers": 8,
          "current_peers": 2,
          "tunnel_exit_enabled": true,
          "host_online": false
        }
        """
        let info = try JSONDecoder().decode(ServerPoolInfo.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(info.hostOnline)
        XCTAssertTrue(info.tunnelExitEnabled)
    }

    func testServerPoolInfoDecodesWithoutHostOnlineDefaultsToTrue() throws {
        // Legacy relay JSON that pre-dates the `host_online` field. We must default to
        // `true` so existing v0.4.x relays keep working with the v0.5.0 client.
        let json = """
        {
          "pool_id": "44444444-4444-4444-4444-444444444444",
          "name": "test",
          "host_peer_id": "peer1",
          "max_peers": 8,
          "current_peers": 2
        }
        """
        let info = try JSONDecoder().decode(ServerPoolInfo.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(info.hostOnline, "missing host_online must default to true")
        XCTAssertFalse(info.tunnelExitEnabled, "missing tunnel_exit_enabled must default to false")
    }

    func testServerPoolInfoRoundTripWithHostOnline() throws {
        let info = ServerPoolInfo(
            poolId: UUID(),
            name: "p",
            hostPeerId: "h",
            maxPeers: 4,
            currentPeers: 2,
            tunnelExitEnabled: true,
            hostOnline: false
        )
        let data = try JSONEncoder().encode(info)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"host_online\":false"), json)
        let decoded = try JSONDecoder().decode(ServerPoolInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    // MARK: - JoinAccepted carrying host_online

    func testJoinAcceptedDecodesWithHostOnlineFalse() throws {
        let json = """
        {
          "frame_type": "join_accepted",
          "data": {
            "session_token": "tok",
            "peer_id": "peer-A",
            "peers": [],
            "pool_info": {
              "pool_id": "55555555-5555-5555-5555-555555555555",
              "name": "p",
              "host_peer_id": "host",
              "max_peers": 8,
              "current_peers": 1,
              "tunnel_exit_enabled": false,
              "host_online": false
            }
          }
        }
        """
        let frame = try ServerFrame.fromJSON(json.data(using: .utf8)!)
        guard case .joinAccepted(let data) = frame else {
            return XCTFail("expected .joinAccepted, got \(frame)")
        }
        XCTAssertFalse(data.poolInfo.hostOnline)
    }

    // MARK: - JoinRejected reason string for host-offline

    func testJoinRejectedHostOfflineUnavailableReasonDecodes() throws {
        let json = """
        {
          "frame_type": "join_rejected",
          "data": { "reason": "host_offline_unavailable" }
        }
        """
        let frame = try ServerFrame.fromJSON(json.data(using: .utf8)!)
        guard case .joinRejected(let payload) = frame else {
            return XCTFail("expected .joinRejected, got \(frame)")
        }
        XCTAssertEqual(payload.reason, "host_offline_unavailable")
    }
}
