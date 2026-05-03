// ServerFrameTunnelFramesTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class ServerFrameTunnelFramesTests: XCTestCase {

    private func roundTrip(_ frame: ServerFrame) throws -> ServerFrame {
        let data = try frame.toJSON()
        return try ServerFrame.fromJSON(data)
    }

    // MARK: - tunnel_open

    func testTunnelOpenHostnameRoundTrip() throws {
        let frame: ServerFrame = .tunnelOpen(TunnelOpenData(
            streamId: 7,
            destination: .hostname(host: "example.com", port: 443),
            network: .tcp,
            initialWindow: TunnelLimits.initialReceiveWindow
        ))
        XCTAssertEqual(try roundTrip(frame), frame)
        let json = String(decoding: try frame.toJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"frame_type\":\"tunnel_open\""))
        XCTAssertTrue(json.contains("\"kind\":\"hostname\""))
        XCTAssertTrue(json.contains("\"host\":\"example.com\""))
        XCTAssertTrue(json.contains("\"initial_window\":262144"))
        XCTAssertTrue(json.contains("\"network\":\"tcp\""))
    }

    func testTunnelOpenIPv4RoundTrip() throws {
        let frame: ServerFrame = .tunnelOpen(TunnelOpenData(
            streamId: 1,
            destination: .ipv4(address: "203.0.113.7", port: 8080),
            network: .tcp,
            initialWindow: 65_536
        ))
        XCTAssertEqual(try roundTrip(frame), frame)
        let json = String(decoding: try frame.toJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\":\"ipv4\""))
        XCTAssertTrue(json.contains("\"address\":\"203.0.113.7\""))
    }

    func testTunnelOpenIPv6UDPRoundTrip() throws {
        let frame: ServerFrame = .tunnelOpen(TunnelOpenData(
            streamId: 99,
            destination: .ipv6(address: "2001:db8::1", port: 53),
            network: .udp,
            initialWindow: 4096
        ))
        XCTAssertEqual(try roundTrip(frame), frame)
        let json = String(decoding: try frame.toJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"kind\":\"ipv6\""))
        XCTAssertTrue(json.contains("\"address\":\"2001:db8::1\""))
        XCTAssertTrue(json.contains("\"network\":\"udp\""))
    }

    // MARK: - tunnel_close

    func testTunnelCloseRoundTripAllReasons() throws {
        for reason in [TunnelCloseReason.peerClosed, .aborted, .idleTimeout, .policyDenied,
                       .destinationUnreachable, .connectionRefused, .timeout, .streamLimit, .protocolError] {
            let frame: ServerFrame = .tunnelClose(TunnelCloseData(streamId: 11, reason: reason))
            XCTAssertEqual(try roundTrip(frame), frame, "round trip failed for reason \(reason.rawValue)")
        }
    }

    func testTunnelCloseSnakeCaseDiscriminator() throws {
        let frame: ServerFrame = .tunnelClose(TunnelCloseData(streamId: 1, reason: .destinationUnreachable))
        let json = String(decoding: try frame.toJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"frame_type\":\"tunnel_close\""))
        XCTAssertTrue(json.contains("\"reason\":\"destination_unreachable\""))
        XCTAssertTrue(json.contains("\"stream_id\":1"))
    }

    // MARK: - tunnel_window_update

    func testTunnelWindowUpdateRoundTrip() throws {
        let frame: ServerFrame = .tunnelWindowUpdate(TunnelWindowUpdateData(streamId: 5, additionalCredit: 65_536))
        XCTAssertEqual(try roundTrip(frame), frame)
        let json = String(decoding: try frame.toJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"frame_type\":\"tunnel_window_update\""))
        XCTAssertTrue(json.contains("\"additional_credit\":65536"))
    }

    // MARK: - tunnel_dns_query

    func testTunnelDnsQueryRoundTripAllRecordTypes() throws {
        for type in [DnsRecordType.a, .aaaa, .cname, .txt] {
            let frame: ServerFrame = .tunnelDnsQuery(TunnelDnsQueryData(queryId: 1, name: "example.com", type: type))
            XCTAssertEqual(try roundTrip(frame), frame, "round trip failed for record type \(type.rawValue)")
        }
    }

    func testTunnelDnsQueryUsesTypeKeyOnTheWire() throws {
        let frame: ServerFrame = .tunnelDnsQuery(TunnelDnsQueryData(queryId: 42, name: "example.com", type: .aaaa))
        let json = String(decoding: try frame.toJSON(), as: UTF8.self)
        // Wire key MUST be `type`, not `record_type`.
        XCTAssertTrue(json.contains("\"type\":\"aaaa\""), "expected wire key \"type\" in: \(json)")
        XCTAssertFalse(json.contains("\"record_type\""), "must not leak Swift property name on wire: \(json)")
        XCTAssertTrue(json.contains("\"query_id\":42"))
    }

    // MARK: - tunnel_dns_response

    func testTunnelDnsResponseAnswersRoundTrip() throws {
        let answers: [DnsAnswer] = [
            DnsAnswer(name: "example.com", type: .a, ttl: 300, value: "93.184.216.34")
        ]
        let frame: ServerFrame = .tunnelDnsResponse(TunnelDnsResponseData(queryId: 1, answers: answers, error: nil))
        XCTAssertEqual(try roundTrip(frame), frame)
    }

    func testTunnelDnsResponseErrorRoundTrip() throws {
        for code in [DnsErrorCode.nxDomain, .servFail, .timeout, .policyDenied, .protocolError] {
            let frame: ServerFrame = .tunnelDnsResponse(TunnelDnsResponseData(
                queryId: 7,
                answers: nil,
                error: DnsError(code: code, message: "demo")
            ))
            XCTAssertEqual(try roundTrip(frame), frame, "round trip failed for DNS code \(code.rawValue)")
        }
    }

    // MARK: - tunnel_error

    func testTunnelErrorRoundTripAllCodes() throws {
        for code in [TunnelErrorCode.policyDenied, .destinationUnreachable, .connectionRefused,
                     .timeout, .protocolError, .resourceExhausted] {
            let frame: ServerFrame = .tunnelError(TunnelErrorData(streamId: 4, code: code, message: "demo"))
            XCTAssertEqual(try roundTrip(frame), frame, "round trip failed for code \(code.rawValue)")
        }
    }

    func testTunnelErrorWithoutStreamId() throws {
        let frame: ServerFrame = .tunnelError(TunnelErrorData(streamId: nil, code: .resourceExhausted, message: "global cap"))
        XCTAssertEqual(try roundTrip(frame), frame)
        let json = String(decoding: try frame.toJSON(), as: UTF8.self)
        // streamId is optional -- when nil, the field should be encoded as null or absent.
        // Default JSONEncoder emits `null` for `Optional.none`.
        XCTAssertTrue(json.contains("\"stream_id\":null") || !json.contains("\"stream_id\""))
    }

    // MARK: - TunnelLimits stability

    func testTunnelLimitsAreStable() {
        XCTAssertEqual(TunnelLimits.maxDataChunkBytes, 32_768)
        XCTAssertEqual(TunnelLimits.initialReceiveWindow, 262_144)
        XCTAssertEqual(TunnelLimits.windowUpdateThreshold, 65_536)
        XCTAssertEqual(TunnelLimits.maxConcurrentStreamsPerPeer, 64)
        XCTAssertEqual(TunnelLimits.maxConcurrentStreamsHostTotal, 256)
    }
}
