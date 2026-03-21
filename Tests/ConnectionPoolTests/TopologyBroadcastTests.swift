// TopologyBroadcastTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class TopologyBroadcastTests: XCTestCase {

    func testTopologyBroadcastEncodeDecode() {
        let broadcast = TopologyBroadcast(
            peerID: "peer-A",
            directNeighbors: ["peer-B", "peer-C"]
        )
        let data = try! JSONEncoder().encode(broadcast)
        let decoded = try! JSONDecoder().decode(TopologyBroadcast.self, from: data)
        XCTAssertEqual(decoded.peerID, "peer-A")
        XCTAssertEqual(decoded.directNeighbors, ["peer-B", "peer-C"])
    }

    func testTopologyBroadcastWrapperRoundTrip() {
        let broadcast = TopologyBroadcast(
            peerID: "node",
            directNeighbors: ["x", "y"]
        )
        let broadcastData = try! JSONEncoder().encode(broadcast)
        let wrapper = TopologyBroadcastWrapper(topologyData: broadcastData)
        let wrappedData = try! JSONEncoder().encode(wrapper)

        let unwrapped = TopologyBroadcastWrapper.unwrap(wrappedData)
        XCTAssertNotNil(unwrapped)
        XCTAssertEqual(unwrapped?.peerID, "node")
        XCTAssertEqual(unwrapped?.directNeighbors, ["x", "y"])
    }

    func testTopologyBroadcastWrapperReturnsNilForNonTopologyData() {
        let garbage = Data("{\"type\":\"not_topology\"}".utf8)
        XCTAssertNil(TopologyBroadcastWrapper.unwrap(garbage))
    }
}
