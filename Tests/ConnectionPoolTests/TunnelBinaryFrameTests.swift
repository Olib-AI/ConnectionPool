// TunnelBinaryFrameTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class TunnelBinaryFrameTests: XCTestCase {

    // MARK: - tunnel_data round-trip

    func testTunnelDataRoundTrip() throws {
        let payload = Data((0..<512).map { UInt8($0 & 0xff) })
        let bytes = encodeTunnelData(streamID: 0x01020304, sequence: 0xAABBCCDD, payload: payload)
        XCTAssertEqual(bytes.count, 9 + payload.count)
        XCTAssertEqual(bytes[0], 0x01)
        // Big-endian header check
        XCTAssertEqual(bytes[1], 0x01); XCTAssertEqual(bytes[2], 0x02)
        XCTAssertEqual(bytes[3], 0x03); XCTAssertEqual(bytes[4], 0x04)
        XCTAssertEqual(bytes[5], 0xAA); XCTAssertEqual(bytes[6], 0xBB)
        XCTAssertEqual(bytes[7], 0xCC); XCTAssertEqual(bytes[8], 0xDD)

        let decoded = decodeTunnelBinary(bytes)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .data)
        XCTAssertEqual(decoded?.streamID, 0x01020304)
        XCTAssertEqual(decoded?.sequence, 0xAABBCCDD)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testTunnelDataEmptyPayloadRoundTrip() {
        let bytes = encodeTunnelData(streamID: 1, sequence: 1, payload: Data())
        XCTAssertEqual(bytes.count, 9)
        let decoded = decodeTunnelBinary(bytes)
        XCTAssertEqual(decoded?.payload, Data())
        XCTAssertEqual(decoded?.streamID, 1)
        XCTAssertEqual(decoded?.sequence, 1)
        XCTAssertEqual(decoded?.type, .data)
    }

    // MARK: - tunnel_udp round-trip

    func testTunnelUdpRoundTrip() {
        let payload = Data([0x10, 0x20, 0x30, 0x40, 0x50])
        let bytes = encodeTunnelUdp(streamID: 0xDEADBEEF, payload: payload)
        XCTAssertEqual(bytes.count, 5 + payload.count)
        XCTAssertEqual(bytes[0], 0x02)
        // Big-endian header
        XCTAssertEqual(bytes[1], 0xDE); XCTAssertEqual(bytes[2], 0xAD)
        XCTAssertEqual(bytes[3], 0xBE); XCTAssertEqual(bytes[4], 0xEF)

        let decoded = decodeTunnelBinary(bytes)
        XCTAssertEqual(decoded?.type, .udp)
        XCTAssertEqual(decoded?.streamID, 0xDEADBEEF)
        XCTAssertNil(decoded?.sequence)
        XCTAssertEqual(decoded?.payload, payload)
    }

    func testTunnelUdpEmptyPayload() {
        let bytes = encodeTunnelUdp(streamID: 7, payload: Data())
        XCTAssertEqual(bytes.count, 5)
        let decoded = decodeTunnelBinary(bytes)
        XCTAssertEqual(decoded?.payload, Data())
        XCTAssertEqual(decoded?.streamID, 7)
    }

    // MARK: - Rejection cases

    func testEmptyFrameRejected() {
        XCTAssertNil(decodeTunnelBinary(Data()))
    }

    func testFramingErrorSentinel0x00Rejected() {
        // 0x00 byte is reserved as framing-error sentinel.
        XCTAssertNil(decodeTunnelBinary(Data([0x00, 0x01, 0x02, 0x03, 0x04])))
    }

    func testReservedRangeRejected() {
        // 0x80...0xFF reserved.
        for byte: UInt8 in [0x80, 0xFE, 0xFF] {
            var bytes = Data([byte])
            bytes.append(Data([0x00, 0x00, 0x00, 0x01]))
            XCTAssertNil(decodeTunnelBinary(bytes), "byte 0x\(String(byte, radix: 16)) should be rejected")
        }
    }

    func testUnknownTypeByteRejected() {
        // 0x03...0x7F not currently defined.
        for byte: UInt8 in [0x03, 0x10, 0x7F] {
            var bytes = Data([byte])
            bytes.append(Data([0x00, 0x00, 0x00, 0x01]))
            XCTAssertNil(decodeTunnelBinary(bytes), "byte 0x\(String(byte, radix: 16)) should be rejected as unknown")
        }
    }

    func testShortDataFrameRejected() {
        // Data frames need at least 9 bytes (1 type + 4 streamID + 4 sequence).
        for shortLen in 1...8 {
            var bytes = Data([0x01])
            bytes.append(Data(repeating: 0xAA, count: shortLen - 1))
            XCTAssertNil(decodeTunnelBinary(bytes), "data frame of length \(shortLen) should be rejected")
        }
    }

    func testShortUdpFrameRejected() {
        // UDP frames need at least 5 bytes (1 type + 4 streamID).
        for shortLen in 1...4 {
            var bytes = Data([0x02])
            bytes.append(Data(repeating: 0xAA, count: shortLen - 1))
            XCTAssertNil(decodeTunnelBinary(bytes), "udp frame of length \(shortLen) should be rejected")
        }
    }

    // MARK: - Big-endian byte order

    func testBigEndianByteOrderForStreamID() {
        // Hand-craft a frame so we can verify byte order without relying on the encoder.
        var bytes = Data()
        bytes.append(0x01)                              // type: data
        bytes.append(contentsOf: [0xCA, 0xFE, 0xBA, 0xBE]) // stream_id big-endian
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x05]) // sequence big-endian
        let decoded = decodeTunnelBinary(bytes)
        XCTAssertEqual(decoded?.streamID, 0xCAFEBABE)
        XCTAssertEqual(decoded?.sequence, 5)
    }
}
