// ProofOfWorkTests.swift
// ConnectionPoolTests
//
// A malicious or broken relay must not be able to pin the client's CPU: difficulty cap,
// strict challenge shape, wall-clock budget and cancellation.

import Foundation
import Testing
@testable import ConnectionPool

@Suite("Proof-of-work hardening")
struct ProofOfWorkTests {

    static let challenge = Data((0..<32).map { UInt8($0 + 0x42) })
    static let challengeB64 = challenge.base64EncodedString()

    static func message(challenge: String = challengeB64, difficulty: String = "18", timestamp: String = "1714752345") -> String {
        "proof-of-work required: {\"challenge\":\"\(challenge)\",\"difficulty\":\(difficulty),\"timestamp\":\(timestamp)}"
    }

    @Test("The cap matches the relay's top difficulty tier (26)")
    func capValue() {
        #expect(ProofOfWork.maxAcceptedDifficulty == 26)
        #expect(ProofOfWork.challengeLength == 32)
        #expect(ProofOfWork.defaultTimeBudget < .seconds(120), "must finish inside the relay's challenge lifetime")
    }

    @Test("Difficulty at the cap parses")
    func atCap() throws {
        let c = try ProofOfWork.parse(message: Self.message(difficulty: "26")).get()
        #expect(c.difficulty == 26)
        #expect(c.bytes == Self.challenge)
        #expect(c.base64 == Self.challengeB64)
    }

    @Test("Difficulty over the cap is refused at parse time", arguments: [27, 32, 64, 128, 200, 255])
    func overCapParse(_ d: Int) {
        #expect(ProofOfWork.parse(message: Self.message(difficulty: String(d))) == .failure(.difficultyTooHigh(UInt8(d))))
    }

    @Test("Maximum-difficulty (255) challenge is refused immediately by the solver")
    func maxDifficultyQuick() {
        let clock = ContinuousClock()
        let start = clock.now
        var thrown: ProofOfWork.Failure?
        do throws(ProofOfWork.Failure) {
            _ = try ProofOfWork.solve(challenge: Self.challenge, difficulty: 255, deadline: .now.advanced(by: .seconds(3600)), isCancelled: { false })
        } catch {
            thrown = error
        }
        #expect(thrown == .difficultyTooHigh(255))
        #expect(clock.now - start < .milliseconds(50))
    }

    @Test("Over-cap difficulty is refused by the solver even when parse is bypassed", arguments: [27, 100])
    func overCapSolve(_ d: Int) {
        #expect(throws: ProofOfWork.Failure.difficultyTooHigh(UInt8(d))) {
            try ProofOfWork.solve(challenge: Self.challenge, difficulty: UInt8(d), deadline: .now.advanced(by: .seconds(60)), isCancelled: { false })
        }
    }

    @Test("A difficulty at the cap with an exhausted budget times out quickly")
    func timeBudget() {
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: ProofOfWork.Failure.timedOut) {
            try ProofOfWork.solve(challenge: Self.challenge, difficulty: 26, deadline: .now.advanced(by: .milliseconds(150)), isCancelled: { false })
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test("Cancellation stops the search (closure)")
    func cancellationClosure() {
        var polls = 0
        #expect(throws: ProofOfWork.Failure.cancelled) {
            try ProofOfWork.solve(challenge: Self.challenge, difficulty: 26, deadline: .now.advanced(by: .seconds(600)), isCancelled: {
                polls += 1
                return polls > 3
            })
        }
        #expect(polls == 4)
    }

    @Test("Cancellation stops the search (structured Task cancellation)")
    func cancellationTask() async {
        let task = Task.detached { () -> ProofOfWork.Failure? in
            do throws(ProofOfWork.Failure) {
                _ = try ProofOfWork.solve(challenge: ProofOfWorkTests.challenge, difficulty: 26, deadline: .now.advanced(by: .seconds(600)))
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        let result = await task.value
        // It may legitimately have found a solution in 20 ms, but must never keep running.
        #expect(result == .cancelled || result == nil)
        #expect(clock.now - start < .seconds(2))
    }

    @Test("Malformed challenges are refused", arguments: [
        "",
        "proof-of-work required",
        "proof-of-work required: {",
        "proof-of-work required: {}",
        "proof-of-work required: not json {at all",
        ProofOfWorkTests.message(challenge: "!!!not-base64!!!"),
        ProofOfWorkTests.message(challenge: Data(count: 31).base64EncodedString()),
        ProofOfWorkTests.message(challenge: Data(count: 33).base64EncodedString()),
        ProofOfWorkTests.message(challenge: ""),
        ProofOfWorkTests.message(difficulty: "256"),
        ProofOfWorkTests.message(difficulty: "-1"),
        ProofOfWorkTests.message(difficulty: "18.5"),
        ProofOfWorkTests.message(difficulty: "\"18\""),
        ProofOfWorkTests.message(difficulty: "null"),
        ProofOfWorkTests.message(timestamp: "\"now\""),
        "{\"challenge\":123,\"difficulty\":18,\"timestamp\":1}",
    ])
    func malformed(_ message: String) {
        #expect(ProofOfWork.parse(message: message) == .failure(.malformedChallenge))
    }

    @Test("The solver refuses a challenge of the wrong length", arguments: [0, 1, 31, 33, 64])
    func wrongLengthSolve(_ length: Int) {
        #expect(throws: ProofOfWork.Failure.malformedChallenge) {
            try ProofOfWork.solve(challenge: Data(count: length), difficulty: 1, deadline: .now.advanced(by: .seconds(5)), isCancelled: { false })
        }
    }

    @Test("Failure descriptions are user-readable")
    func descriptions() {
        #expect(ProofOfWork.Failure.difficultyTooHigh(40).description.contains("40"))
        #expect(ProofOfWork.Failure.difficultyTooHigh(40).description.contains("26"))
        #expect(!ProofOfWork.Failure.timedOut.description.isEmpty)
        #expect(!ProofOfWork.Failure.malformedChallenge.description.isEmpty)
    }
}
