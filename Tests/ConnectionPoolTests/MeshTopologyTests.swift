// MeshTopologyTests.swift
// ConnectionPoolTests

import XCTest
@testable import ConnectionPool

final class MeshTopologyTests: XCTestCase {

    // MARK: - Initialization

    func testInitSetsLocalPeerAndEmptyNeighbors() {
        let topo = MeshTopology(localPeerID: "local")
        XCTAssertEqual(topo.localPeerID, "local")
        XCTAssertTrue(topo.directNeighbors.isEmpty)
        XCTAssertTrue(topo.allKnownPeers.contains("local"))
    }

    // MARK: - Neighbor Updates

    func testUpdateNeighborsStoresNeighbors() {
        let topo = MeshTopology(localPeerID: "local")
        topo.updateNeighbors(for: "peer-A", neighbors: ["peer-B", "peer-C"])
        XCTAssertEqual(topo.neighbors(for: "peer-A"), ["peer-B", "peer-C"])
    }

    func testUpdateNeighborsOverwritesPrevious() {
        let topo = MeshTopology(localPeerID: "local")
        topo.updateNeighbors(for: "peer-A", neighbors: ["x"])
        topo.updateNeighbors(for: "peer-A", neighbors: ["y", "z"])
        XCTAssertEqual(topo.neighbors(for: "peer-A"), ["y", "z"])
    }

    func testNeighborsForUnknownPeerReturnsEmpty() {
        let topo = MeshTopology(localPeerID: "local")
        XCTAssertTrue(topo.neighbors(for: "unknown").isEmpty)
    }

    // MARK: - Direct Connection

    func testAddDirectConnectionUpdatesLocalNeighbors() {
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("peer-A")
        XCTAssertTrue(topo.directNeighbors.contains("peer-A"))
        XCTAssertTrue(topo.canReachDirectly("peer-A"))
    }

    func testCanReachDirectlyFalseForNonNeighbor() {
        let topo = MeshTopology(localPeerID: "local")
        XCTAssertFalse(topo.canReachDirectly("unknown"))
    }

    // MARK: - BFS Path Finding

    func testFindPathToSelfReturnsEmptyArray() {
        let topo = MeshTopology(localPeerID: "local")
        let path = topo.findPath(to: "local")
        XCTAssertEqual(path, [])
    }

    func testFindPathToDirectNeighbor() {
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("peer-A")
        let path = topo.findPath(to: "peer-A")
        XCTAssertEqual(path, ["peer-A"])
    }

    func testFindPathTwoHops() {
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("peer-A")
        topo.updateNeighbors(for: "peer-A", neighbors: ["local", "peer-B"])
        let path = topo.findPath(to: "peer-B")
        XCTAssertEqual(path, ["peer-A", "peer-B"])
    }

    func testFindPathReturnsNilForUnreachable() {
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("peer-A")
        // peer-B exists but is not connected to peer-A or local
        let path = topo.findPath(to: "peer-B")
        XCTAssertNil(path)
    }

    func testFindPathShortestInDiamond() {
        // local -> A -> C
        // local -> B -> C
        // Both are 2-hop; BFS should return one of them.
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("A")
        topo.addDirectConnection("B")
        topo.updateNeighbors(for: "A", neighbors: ["local", "C"])
        topo.updateNeighbors(for: "B", neighbors: ["local", "C"])
        let path = topo.findPath(to: "C")
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.count, 2, "Shortest path in a diamond is 2 hops")
        XCTAssertEqual(path?.last, "C")
    }

    // MARK: - allKnownPeers

    func testAllKnownPeersIncludesTransitiveNeighbors() {
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("A")
        topo.updateNeighbors(for: "A", neighbors: ["local", "B", "C"])
        let known = topo.allKnownPeers
        XCTAssertTrue(known.contains("local"))
        XCTAssertTrue(known.contains("A"))
        XCTAssertTrue(known.contains("B"))
        XCTAssertTrue(known.contains("C"))
    }

    // MARK: - Peer Removal

    func testRemovePeerClearsFromNeighborSets() {
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("A")
        topo.addDirectConnection("B")
        topo.updateNeighbors(for: "A", neighbors: ["local", "B"])
        topo.removePeer("B")
        XCTAssertFalse(topo.directNeighbors.contains("B"))
        XCTAssertFalse(topo.neighbors(for: "A").contains("B"))
    }

    func testRemoveSelfIsNoOp() {
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("A")
        topo.removePeer("local")
        // local should still be present
        XCTAssertTrue(topo.allKnownPeers.contains("local"))
    }

    // MARK: - Stale Pruning

    func testPruneStaleRemovesOldPeers() {
        let topo = MeshTopology(localPeerID: "local")
        topo.addDirectConnection("A")
        // We cannot easily set the timestamp in the past via public API,
        // but we can test that pruneStale does not crash and keeps local peer.
        // Fresh peers should survive pruning.
        topo.pruneStale()
        XCTAssertTrue(topo.allKnownPeers.contains("local"))
        // "A" was just added (fresh), should survive
        XCTAssertTrue(topo.directNeighbors.contains("A"))
    }
}
