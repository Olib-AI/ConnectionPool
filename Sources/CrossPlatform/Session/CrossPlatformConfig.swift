// CrossPlatformConfig.swift
// ConnectionPool / CrossPlatform
//
// Configuration for the local app's `CrossPlatformPool`. One instance per
// process. Mirrors Kotlin `PoolConfig.kt`.
//
// `localPID` is the install-stable 16-byte peer ID. Persist it on first run
// and pass the same bytes here forever after.
//
// `maxPeers` is pinned to **2** for M0 (host + 1 guest) per ADR-0001's
// chess-pool semantics. The host accepts at most `maxPeers - 1 = 1` guest;
// the second concurrent guest receives `CrossPlatformTransportError.full`. Future product
// surfaces wanting a different cap MUST be motivated by a new ADR.

import Foundation

public struct CrossPlatformConfig: Sendable {
    public let localPID: Data
    public let localDisplayName: String
    public let poolName: String
    public let maxPeers: Int

    public init(
        localPID: Data,
        localDisplayName: String,
        poolName: String? = nil,
        maxPeers: Int = 2
    ) {
        precondition(localPID.count == 16, "localPID must be exactly 16 bytes")
        precondition(!localDisplayName.isEmpty, "localDisplayName must be non-blank")
        precondition(localDisplayName.utf8.count <= 32, "localDisplayName must be ≤32 UTF-8 bytes")
        let name = poolName ?? localDisplayName
        precondition(name.utf8.count <= 40, "poolName must be ≤40 UTF-8 bytes")
        precondition(maxPeers == 2, "maxPeers must be 2 (chess is strictly 1v1 in v1)")
        self.localPID = localPID
        self.localDisplayName = localDisplayName
        self.poolName = name
        self.maxPeers = maxPeers
    }
}
