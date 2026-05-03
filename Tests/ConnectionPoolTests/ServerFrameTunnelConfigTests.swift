// ServerFrameTunnelConfigTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class ServerFrameTunnelConfigTests: XCTestCase {

    // MARK: - update_pool_config (client -> server)

    func testUpdatePoolConfigRoundTrip() throws {
        let frame: ServerFrame = .updatePoolConfig(UpdatePoolConfigData(
            tunnelExitEnabled: true,
            sessionToken: "tok123"
        ))
        let data = try frame.toJSON()
        let decoded = try ServerFrame.fromJSON(data)
        XCTAssertEqual(frame, decoded)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"frame_type\":\"update_pool_config\""), "expected frame_type discriminator: \(json)")
        XCTAssertTrue(json.contains("\"tunnel_exit_enabled\":true"), "expected snake_case key: \(json)")
        XCTAssertTrue(json.contains("\"session_token\":\"tok123\""))
    }

    func testUpdatePoolConfigOmitsNilFields() throws {
        let frame: ServerFrame = .updatePoolConfig(UpdatePoolConfigData(tunnelExitEnabled: nil, sessionToken: nil))
        let data = try frame.toJSON()
        let json = String(decoding: data, as: UTF8.self)
        // encodeIfPresent — both keys should be absent.
        XCTAssertFalse(json.contains("tunnel_exit_enabled"), json)
        XCTAssertFalse(json.contains("session_token"), json)
        // Round-trip decode still works.
        let decoded = try ServerFrame.fromJSON(data)
        XCTAssertEqual(frame, decoded)
    }

    // MARK: - pool_config_updated (server -> client)

    func testPoolConfigUpdatedRoundTrip() throws {
        let frame: ServerFrame = .poolConfigUpdated(PoolConfigUpdatedData(
            tunnelExitEnabled: false,
            updatedByHost: true
        ))
        let data = try frame.toJSON()
        let decoded = try ServerFrame.fromJSON(data)
        XCTAssertEqual(frame, decoded)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"frame_type\":\"pool_config_updated\""))
        XCTAssertTrue(json.contains("\"updated_by_host\":true"))
    }

    // MARK: - HostAuthData legacy compatibility

    func testHostAuthDataLegacyDecodeWithoutTunnelExitField() throws {
        let legacyJSON = """
        {
          "frame_type": "host_auth",
          "data": {
            "host_public_key": "AAA=",
            "timestamp": 1234567890,
            "signature": "sig",
            "pool_id": "11111111-1111-1111-1111-111111111111",
            "nonce": "n"
          }
        }
        """
        let data = legacyJSON.data(using: .utf8)!
        let frame = try ServerFrame.fromJSON(data)
        guard case .hostAuth(let hostAuth) = frame else {
            return XCTFail("Expected hostAuth, got \(frame)")
        }
        XCTAssertNil(hostAuth.tunnelExitEnabled)
        XCTAssertNil(hostAuth.serverUrl)
        XCTAssertNil(hostAuth.displayName)
    }

    func testHostAuthDataRoundTripWithTunnelExitField() throws {
        let original = HostAuthData(
            hostPublicKey: "pk",
            timestamp: 1,
            signature: "sig",
            poolId: UUID(),
            serverUrl: "ws://x",
            displayName: "Alice",
            nonce: "n",
            tunnelExitEnabled: true
        )
        let frame: ServerFrame = .hostAuth(original)
        let encoded = try frame.toJSON()
        let decoded = try ServerFrame.fromJSON(encoded)
        guard case .hostAuth(let roundTripped) = decoded else {
            return XCTFail("Expected hostAuth")
        }
        XCTAssertEqual(roundTripped.tunnelExitEnabled, true)
        XCTAssertEqual(roundTripped, original)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("\"tunnel_exit_enabled\":true"))
    }

    // MARK: - ServerPoolInfo default

    func testServerPoolInfoDecodesWithoutTunnelExitField() throws {
        let legacyJSON = """
        {
          "pool_id": "22222222-2222-2222-2222-222222222222",
          "name": "test",
          "host_peer_id": "peer1",
          "max_peers": 8,
          "current_peers": 1
        }
        """
        let info = try JSONDecoder().decode(ServerPoolInfo.self, from: legacyJSON.data(using: .utf8)!)
        XCTAssertFalse(info.tunnelExitEnabled, "default must be false when field absent")
    }

    func testServerPoolInfoRoundTripWithTunnelExit() throws {
        let info = ServerPoolInfo(
            poolId: UUID(),
            name: "p",
            hostPeerId: "h",
            maxPeers: 4,
            currentPeers: 2,
            tunnelExitEnabled: true
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ServerPoolInfo.self, from: data)
        XCTAssertEqual(decoded.tunnelExitEnabled, true)
        XCTAssertEqual(decoded, info)
    }
}
