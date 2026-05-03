// TunnelBinaryFrame.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - Tunnel Binary Frame Layout
//
// Binary WebSocket frames carry the "hot path" of the relay tunnel — TCP byte stream
// chunks (`tunnel_data`) and UDP datagrams (`tunnel_udp`) — bypassing JSON for low
// per-byte overhead.
//
// All multi-byte fields are big-endian. Layout MUST stay byte-identical with the
// Rust StealthRelay agent's binary tunnel codec.
//
// ```
// TUNNEL_DATA   (ordered TCP byte stream)
//   byte  0      = 0x01
//   bytes 1..5   = stream_id (u32 BE)
//   bytes 5..9   = sequence  (u32 BE)
//   bytes 9..    = payload   (≤ 32 KiB)
//
// TUNNEL_UDP    (unordered UDP datagram)
//   byte  0      = 0x02
//   bytes 1..5   = stream_id (u32 BE)
//   bytes 5..    = payload
// ```
//
// Type byte `0x00` is reserved as a framing-error sentinel.
// `0x80...0xFF` are reserved for future expansion. Any unknown type MUST cause a
// `tunnel_error{code: protocol_error}` and treating the originating stream as closed.

/// Binary tunnel frame type discriminator (first byte of every binary frame).
enum TunnelBinaryType: UInt8 {
    case data = 0x01
    case udp  = 0x02
}

/// Decoded representation of one binary tunnel frame.
struct DecodedTunnelBinaryFrame: Equatable {
    let type: TunnelBinaryType
    let streamID: UInt32
    /// Sequence number, present for `.data` only. `nil` for `.udp`.
    let sequence: UInt32?
    let payload: Data
}

/// Build a `TUNNEL_DATA` binary frame.
///
/// - Parameters:
///   - streamID: u32 stream identifier (big-endian on the wire).
///   - sequence: u32 monotonic sequence number (big-endian on the wire).
///   - payload: ordered byte chunk; up to `TunnelLimits.maxDataChunkBytes`.
/// - Returns: 9-byte header + payload. No allocation beyond the returned `Data`.
@inline(__always)
func encodeTunnelData(streamID: UInt32, sequence: UInt32, payload: Data) -> Data {
    var out = Data(capacity: 9 + payload.count)
    out.append(TunnelBinaryType.data.rawValue)
    appendBigEndianUInt32(&out, streamID)
    appendBigEndianUInt32(&out, sequence)
    out.append(payload)
    return out
}

/// Build a `TUNNEL_UDP` binary frame.
///
/// - Parameters:
///   - streamID: u32 stream identifier (big-endian on the wire).
///   - payload: single datagram body.
/// - Returns: 5-byte header + payload.
@inline(__always)
func encodeTunnelUdp(streamID: UInt32, payload: Data) -> Data {
    var out = Data(capacity: 5 + payload.count)
    out.append(TunnelBinaryType.udp.rawValue)
    appendBigEndianUInt32(&out, streamID)
    out.append(payload)
    return out
}

/// Decode a binary tunnel frame.
///
/// Performs strict bounds checking. Returns `nil` for:
/// - empty frames
/// - frames whose first byte is the reserved `0x00` sentinel
/// - frames whose first byte is in the reserved `0x80...0xFF` range
/// - frames shorter than the type-specific header
///
/// - Parameter frame: full WebSocket binary message bytes.
/// - Returns: parsed (type, streamID, sequence?, payload) tuple, or `nil` on framing error.
@inline(__always)
func decodeTunnelBinary(_ frame: Data) -> DecodedTunnelBinaryFrame? {
    guard let typeByte = frame.first else { return nil }
    guard let type = TunnelBinaryType(rawValue: typeByte) else { return nil }

    return frame.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> DecodedTunnelBinaryFrame? in
        guard let base = buf.baseAddress else { return nil }
        let count = buf.count
        switch type {
        case .data:
            // 1 (type) + 4 (stream_id) + 4 (sequence) = 9 byte header
            guard count >= 9 else { return nil }
            let streamID = readBigEndianUInt32(base, offset: 1)
            let sequence = readBigEndianUInt32(base, offset: 5)
            let payload: Data
            if count == 9 {
                payload = Data()
            } else {
                let payloadStart = frame.startIndex + 9
                payload = frame.subdata(in: payloadStart..<frame.endIndex)
            }
            return DecodedTunnelBinaryFrame(type: .data, streamID: streamID, sequence: sequence, payload: payload)

        case .udp:
            // 1 (type) + 4 (stream_id) = 5 byte header
            guard count >= 5 else { return nil }
            let streamID = readBigEndianUInt32(base, offset: 1)
            let payload: Data
            if count == 5 {
                payload = Data()
            } else {
                let payloadStart = frame.startIndex + 5
                payload = frame.subdata(in: payloadStart..<frame.endIndex)
            }
            return DecodedTunnelBinaryFrame(type: .udp, streamID: streamID, sequence: nil, payload: payload)
        }
    }
}

// MARK: - Big-endian helpers (no extra allocations)

@inline(__always)
private func appendBigEndianUInt32(_ data: inout Data, _ value: UInt32) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { raw in
        data.append(raw.bindMemory(to: UInt8.self).baseAddress!, count: 4)
    }
}

@inline(__always)
private func readBigEndianUInt32(_ base: UnsafeRawPointer, offset: Int) -> UInt32 {
    // Avoid unaligned load by copying through a stack-allocated UInt32.
    var raw: UInt32 = 0
    withUnsafeMutableBytes(of: &raw) { dst in
        _ = memcpy(dst.baseAddress!, base.advanced(by: offset), 4)
    }
    return UInt32(bigEndian: raw)
}
