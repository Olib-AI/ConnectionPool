// RemoteMemberIdentityTests.swift
// ConnectionPoolTests
//
// Verifies the persistent member-identity Keychain layer that backs the
// `member_rejoin` auto-rejoin flow.

import XCTest
import CryptoKit
@testable import ConnectionPool

final class RemoteMemberIdentityTests: XCTestCase {

    // Distinct per-test fixtures so parallel runs don't clobber each other's
    // Keychain slots. We always tear down by calling `delete` in the trailing
    // `tearDown` regardless of whether the test created the slot.
    private var serverURL: String { "wss://test.example/\(name)" }
    private let poolID = UUID().uuidString

    override func tearDownWithError() throws {
        try? RemoteMemberIdentity.delete(serverURL: serverURL, poolID: poolID)
        try super.tearDownWithError()
    }

    // MARK: - existing(...)

    func testExistingReturnsNilBeforeFirstCreate() throws {
        let identity = try RemoteMemberIdentity.existing(serverURL: serverURL, poolID: poolID)
        XCTAssertNil(identity, "existing(...) must return nil when no identity has been created yet")
    }

    // MARK: - loadOrCreate(...)

    func testLoadOrCreateGeneratesOnFirstCallAndReturnsSameOnSecond() throws {
        let first = try RemoteMemberIdentity.loadOrCreate(serverURL: serverURL, poolID: poolID)
        let second = try RemoteMemberIdentity.loadOrCreate(serverURL: serverURL, poolID: poolID)
        XCTAssertEqual(
            first.publicKey.rawRepresentation,
            second.publicKey.rawRepresentation,
            "loadOrCreate must persist and return the same identity across calls"
        )
        XCTAssertEqual(
            first.privateKey.rawRepresentation,
            second.privateKey.rawRepresentation,
            "private key bytes must match — that's the whole point of persistence"
        )
    }

    func testLoadOrCreateScopesByServerAndPool() throws {
        let pool1 = UUID().uuidString
        let pool2 = UUID().uuidString
        defer {
            try? RemoteMemberIdentity.delete(serverURL: serverURL, poolID: pool1)
            try? RemoteMemberIdentity.delete(serverURL: serverURL, poolID: pool2)
            try? RemoteMemberIdentity.delete(serverURL: "wss://other.example", poolID: pool1)
        }
        let a = try RemoteMemberIdentity.loadOrCreate(serverURL: serverURL, poolID: pool1)
        let b = try RemoteMemberIdentity.loadOrCreate(serverURL: serverURL, poolID: pool2)
        let c = try RemoteMemberIdentity.loadOrCreate(serverURL: "wss://other.example", poolID: pool1)

        XCTAssertNotEqual(a.publicKey.rawRepresentation, b.publicKey.rawRepresentation,
                          "different poolIDs must produce distinct identities")
        XCTAssertNotEqual(a.publicKey.rawRepresentation, c.publicKey.rawRepresentation,
                          "different serverURLs must produce distinct identities")
    }

    // MARK: - delete(...)

    func testDeleteRemovesPersistedIdentity() throws {
        _ = try RemoteMemberIdentity.loadOrCreate(serverURL: serverURL, poolID: poolID)
        XCTAssertNotNil(try RemoteMemberIdentity.existing(serverURL: serverURL, poolID: poolID))

        try RemoteMemberIdentity.delete(serverURL: serverURL, poolID: poolID)
        XCTAssertNil(try RemoteMemberIdentity.existing(serverURL: serverURL, poolID: poolID),
                     "delete(...) must remove the identity from the Keychain")
    }

    func testDeleteIsIdempotent() throws {
        // Double delete must not throw.
        try RemoteMemberIdentity.delete(serverURL: serverURL, poolID: poolID)
        try RemoteMemberIdentity.delete(serverURL: serverURL, poolID: poolID)
    }

    func testInstanceDeleteMatchesStaticDelete() throws {
        let identity = try RemoteMemberIdentity.loadOrCreate(serverURL: serverURL, poolID: poolID)
        try identity.delete(serverURL: serverURL, poolID: poolID)
        XCTAssertNil(try RemoteMemberIdentity.existing(serverURL: serverURL, poolID: poolID))
    }

    // MARK: - publicKeyBase64

    func testPublicKeyBase64DecodesToRawBytes() throws {
        let identity = try RemoteMemberIdentity.loadOrCreate(serverURL: serverURL, poolID: poolID)
        let decoded = Data(base64Encoded: identity.publicKeyBase64)
        XCTAssertEqual(decoded, identity.publicKey.rawRepresentation)
        XCTAssertEqual(decoded?.count, 32, "Ed25519 public keys are exactly 32 raw bytes")
    }

    // MARK: - signing

    func testSignatureVerifiesWithPublicKey() throws {
        let identity = try RemoteMemberIdentity.loadOrCreate(serverURL: serverURL, poolID: poolID)
        let transcript = Data("hello-rejoin-transcript".utf8)
        let signature = try identity.sign(transcript: transcript)
        XCTAssertTrue(
            identity.publicKey.isValidSignature(signature, for: transcript),
            "sign(...) must produce a signature that the embedded public key validates"
        )
    }

    // MARK: - Keychain account scheme

    func testKeychainAccountIsPerPoolDistinct() {
        let server = "wss://relay.example"
        let pool1 = "11111111-1111-1111-1111-111111111111"
        let pool2 = "22222222-2222-2222-2222-222222222222"
        let acc1 = RemoteMemberIdentity.keychainAccount(serverURL: server, poolID: pool1)
        let acc2 = RemoteMemberIdentity.keychainAccount(serverURL: server, poolID: pool2)
        XCTAssertNotEqual(acc1, acc2, "different pools must hash to different Keychain accounts")
        XCTAssertTrue(acc1.hasPrefix("member_identity:"), "account must be namespaced with the prefix")
        XCTAssertTrue(acc2.hasPrefix("member_identity:"))
    }

    func testKeychainAccountIsDeterministic() {
        let acc1 = RemoteMemberIdentity.keychainAccount(serverURL: "wss://a", poolID: "p")
        let acc2 = RemoteMemberIdentity.keychainAccount(serverURL: "wss://a", poolID: "p")
        XCTAssertEqual(acc1, acc2, "same inputs must always produce the same Keychain account")
    }
}
