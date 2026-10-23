import XCTest
@testable import CodexMeterCore

/// Integration-level coverage for the ephemeral turn state machine.
///
/// The reviewer's blocking scenario is: A's `thread/start` is in flight, an
/// `account/read` notices account B, then A's reply arrives. It must not reach
/// `turn/start`. That path used to live in the app target, where no test could
/// reach it.
final class CodexWindowTurnBridgeTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/codexmeter-bridge-tests", isDirectory: true)

    private func payload(
        attemptID: String = "A",
        generation: Int = 1
    ) -> WindowStartTurnPayload {
        WindowStartTurnPayload(
            attemptID: attemptID,
            generation: generation,
            model: "gpt-5",
            effort: "low",
            prompt: WindowStartRequest.defaultPrompt,
            workDirectory: directory
        )
    }

    /// Brings a bridge to "thread request sent, waiting for its reply".
    private func bridgeAwaitingThreadReply(
        attemptID: String = "A",
        generation: Int = 1
    ) -> CodexWindowTurnBridge {
        var bridge = CodexWindowTurnBridge()
        _ = bridge.begin(payload(attemptID: attemptID, generation: generation))
        bridge.threadRequestRegistered(id: 10)
        return bridge
    }

    // MARK: - Happy path

    func testBeginSendsOneThreadStart() {
        var bridge = CodexWindowTurnBridge()
        let request = payload()

        XCTAssertEqual(bridge.begin(request), .sendThread(request))
        XCTAssertFalse(bridge.isIdle)
        XCTAssertEqual(bridge.activeAttemptID, "A")
    }

    func testAThreadReplyAdvancesToExactlyOneTurn() {
        var bridge = bridgeAwaitingThreadReply()

        let action = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: "openai"
        )

        XCTAssertEqual(action, .sendTurn(
            attemptID: "A",
            threadID: "thread-A",
            model: "gpt-5",
            effort: "low",
            prompt: WindowStartRequest.defaultPrompt
        ))
    }

    func testASecondThreadReplyCannotOpenASecondTurn() {
        var bridge = bridgeAwaitingThreadReply()
        _ = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: "openai"
        )

        // The same attempt answered twice.
        XCTAssertEqual(
            bridge.receiveThreadReply(
                requestID: 10,
                generation: 1,
                threadID: "thread-A2",
                modelProvider: "openai"
            ),
            .drop
        )
    }

    func testCompletionReportsTheTurnThatWasRecorded() {
        var bridge = bridgeAwaitingThreadReply()
        _ = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: "openai"
        )
        bridge.turnRequestRegistered(id: 11)
        _ = bridge.receiveTurnReply(requestID: 11, generation: 1, turnID: "turn-1")

        let action = bridge.receiveCompletion(
            threadID: "thread-A",
            turnID: "turn-1",
            generation: 1,
            status: "completed",
            errorMessage: nil
        )

        XCTAssertEqual(action, .finish(.completed(turnID: "turn-1", modelProvider: "openai")))
        XCTAssertTrue(bridge.isIdle)
        XCTAssertNil(bridge.payload)
    }

    func testFailedAndInterruptedCompletionsAreReported() {
        for (status, expected): (String, WindowStartTransportResult) in [
            ("interrupted", .interrupted(turnID: "turn-1")),
            ("failed", .turnFailed(turnID: "turn-1", detail: "boom"))
        ] {
            var bridge = bridgeAwaitingThreadReply()
            _ = bridge.receiveThreadReply(
                requestID: 10,
                generation: 1,
                threadID: "thread-A",
                modelProvider: "openai"
            )
            _ = bridge.receiveTurnReply(requestID: 11, generation: 1, turnID: "turn-1")

            XCTAssertEqual(
                bridge.receiveCompletion(
                    threadID: "thread-A",
                    turnID: "turn-1",
                    generation: 1,
                    status: status,
                    errorMessage: "boom"
                ),
                .finish(expected),
                "unexpected result for \(status)"
            )
        }
    }

    // MARK: - Account boundary

    /// The blocking finding: an identity change noticed by `account/read` must
    /// stop the in-flight reply from ever reaching `turn/start`.
    func testAccountBoundaryBeforeTheThreadReplyNeverSendsATurn() {
        var bridge = bridgeAwaitingThreadReply()
        let payloadBefore = bridge.payload

        // `parseAccount` noticed account B.
        let boundary = bridge.accountBoundary()

        XCTAssertEqual(boundary, .abandon(
            requestIDs: [10],
            threadID: nil,
            turnID: nil,
            result: .rejected(.unsupportedAccount)
        ))
        XCTAssertNotNil(payloadBefore)
        XCTAssertTrue(bridge.isIdle)

        // A's reply arrives afterwards and must change nothing.
        XCTAssertEqual(
            bridge.receiveThreadReply(
                requestID: 10,
                generation: 1,
                threadID: "thread-A",
                modelProvider: "openai"
            ),
            .drop
        )
        XCTAssertTrue(bridge.isIdle)
    }

    func testAThreadReplyFromAPreviousGenerationNeverSendsATurn() {
        var bridge = bridgeAwaitingThreadReply()

        // The generation moved on without a separate boundary call.
        let action = bridge.receiveThreadReply(
            requestID: 10,
            generation: 2,
            threadID: "thread-A",
            modelProvider: "openai"
        )

        XCTAssertEqual(action, .abandon(
            requestIDs: [10],
            threadID: nil,
            turnID: nil,
            result: .rejected(.unsupportedAccount)
        ))
        XCTAssertTrue(bridge.isIdle)
    }

    func testBoundaryAfterDispatchKeepsUnknownDelivery() {
        var bridge = bridgeAwaitingThreadReply()
        _ = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: "openai"
        )
        bridge.turnRequestRegistered(id: 11)

        // The message may already have reached the backend, so this is not a
        // clean refusal and the old account's protection must stay.
        XCTAssertEqual(bridge.accountBoundary(), .abandon(
            requestIDs: [10, 11],
            threadID: "thread-A",
            turnID: nil,
            result: .undetermined(.connectionLost)
        ))
    }

    func testCompletionFromAPreviousGenerationDoesNotSettleTheAttempt() {
        var bridge = bridgeAwaitingThreadReply()
        _ = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: "openai"
        )
        bridge.turnRequestRegistered(id: 11)
        _ = bridge.receiveTurnReply(requestID: 11, generation: 1, turnID: "turn-1")

        let action = bridge.receiveCompletion(
            threadID: "thread-A",
            turnID: "turn-1",
            generation: 2,
            status: "completed",
            errorMessage: nil
        )

        XCTAssertEqual(action, .abandon(
            requestIDs: [10, 11],
            threadID: "thread-A",
            turnID: "turn-1",
            result: .undetermined(.connectionLost)
        ))
    }

    func testTurnReplyFromAPreviousGenerationAbandons() {
        var bridge = bridgeAwaitingThreadReply()
        _ = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: "openai"
        )
        bridge.turnRequestRegistered(id: 11)

        XCTAssertEqual(
            bridge.receiveTurnReply(requestID: 11, generation: 2, turnID: "turn-1"),
            .abandon(
                requestIDs: [10, 11],
                threadID: "thread-A",
                turnID: nil,
                result: .undetermined(.connectionLost)
            )
        )
    }

    // MARK: - Foreign and late events

    func testForeignRequestIDIsDropped() {
        var bridge = bridgeAwaitingThreadReply()

        XCTAssertEqual(
            bridge.receiveThreadReply(
                requestID: 99,
                generation: 1,
                threadID: "thread-x",
                modelProvider: "openai"
            ),
            .drop
        )
        XCTAssertEqual(bridge.activeAttemptID, "A")
    }

    func testCompletionForAnotherThreadIsDropped() {
        var bridge = bridgeAwaitingThreadReply()
        _ = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: "openai"
        )
        _ = bridge.receiveTurnReply(requestID: 11, generation: 1, turnID: "turn-1")

        XCTAssertEqual(
            bridge.receiveCompletion(
                threadID: "thread-other",
                turnID: "turn-1",
                generation: 1,
                status: "completed",
                errorMessage: nil
            ),
            .drop
        )
        XCTAssertFalse(bridge.isIdle, "the live attempt must stay in place")
    }

    func testCancelOfAForeignAttemptLeavesTheReplacement() {
        var bridge = bridgeAwaitingThreadReply(attemptID: "B", generation: 2)

        XCTAssertEqual(bridge.cancel(attemptID: "A"), .drop)
        XCTAssertEqual(bridge.activeAttemptID, "B")
        XCTAssertEqual(
            bridge.cancel(attemptID: "B"),
            .abandon(
                requestIDs: [10],
                threadID: nil,
                turnID: nil,
                result: .undetermined(.cancelled)
            )
        )
    }

    func testConcurrentBeginIsRefusedWithoutDispatch() {
        var bridge = bridgeAwaitingThreadReply()

        XCTAssertEqual(
            bridge.begin(payload(attemptID: "B", generation: 1)),
            .finish(.rejected(.concurrentRequest))
        )
        XCTAssertEqual(bridge.activeAttemptID, "A")
    }

    // MARK: - Transport failures

    func testForeignProviderIsRefusedAndTheThreadIsInterrupted() {
        var bridge = bridgeAwaitingThreadReply()

        XCTAssertEqual(
            bridge.receiveThreadReply(
                requestID: 10,
                generation: 1,
                threadID: "thread-A",
                modelProvider: "custom-provider"
            ),
            .abandon(
                requestIDs: [10],
                threadID: "thread-A",
                turnID: nil,
                result: .rejected(.unsupportedAccount)
            )
        )
    }

    func testMissingProviderIsAcceptedBecauseTheConnectionProvedIdentity() {
        var bridge = bridgeAwaitingThreadReply()

        guard case .sendTurn = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: nil
        ) else {
            return XCTFail("a missing provider must fall back to the connection identity")
        }
    }

    func testTransportFailureEndsTheAttempt() {
        var bridge = bridgeAwaitingThreadReply()

        XCTAssertEqual(
            bridge.fail(.rejected(.transportError)),
            .abandon(
                requestIDs: [10],
                threadID: nil,
                turnID: nil,
                result: .rejected(.transportError)
            )
        )
        XCTAssertTrue(bridge.isIdle)
    }

    func testFailAfterDispatchReportsUnknownDelivery() {
        var bridge = bridgeAwaitingThreadReply()
        _ = bridge.receiveThreadReply(
            requestID: 10,
            generation: 1,
            threadID: "thread-A",
            modelProvider: "openai"
        )
        bridge.turnRequestRegistered(id: 11)

        // The caller decides the result; the bridge only reports it.
        guard case let .abandon(requestIDs, threadID, _, result) =
                bridge.fail(.undetermined(.connectionLost)) else {
            return XCTFail("expected an abandonment")
        }
        XCTAssertEqual(requestIDs.sorted(), [10, 11])
        XCTAssertEqual(threadID, "thread-A")
        XCTAssertEqual(result, .undetermined(.connectionLost))
    }
}
