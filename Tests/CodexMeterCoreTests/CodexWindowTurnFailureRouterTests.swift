import XCTest
@testable import CodexMeterCore

/// Mirrors what `CodexUsageService.perform(_:)` does with each action, so these
/// tests exercise the dispatch wiring rather than the bridge helper alone.
private final class FakeTurnExecutor {
    private(set) var threadStartRequests = 0
    private(set) var turnStartRequests = 0
    private(set) var interrupts: [(threadID: String, turnID: String?)] = []
    private(set) var deliveredResults: [WindowStartTransportResult] = []
    private(set) var lastThreadRequestID: Int?

    /// When the App Server is gone, writing an interrupt into the dead pipe must
    /// not be part of the cleanup.
    var transportCanReceiveRequests = true
    private var nextRequestID = 0

    func perform(_ action: CodexWindowTurnBridge.Action, bridge: inout CodexWindowTurnBridge) {
        switch action {
        case .sendThread:
            nextRequestID += 1
            threadStartRequests += 1
            lastThreadRequestID = nextRequestID
            bridge.threadRequestRegistered(id: nextRequestID)

        case .sendTurn:
            nextRequestID += 1
            turnStartRequests += 1
            bridge.turnRequestRegistered(id: nextRequestID)

        case let .abandon(_, threadID, turnID, result):
            if let threadID, transportCanReceiveRequests {
                interrupts.append((threadID, turnID))
            }
            deliveredResults.append(result)

        case let .finish(result):
            deliveredResults.append(result)

        case .drop:
            break
        }
    }
}

final class CodexWindowTurnFailureRouterTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/codexmeter-router-tests", isDirectory: true)

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

    // MARK: - JSON-RPC errors

    /// The blocking finding: an answered error used to leave the bridge occupied,
    /// so every later retry was refused as a concurrent request.
    func testThreadStartErrorReleasesTheAttemptAndAllowsARetry() {
        var bridge = CodexWindowTurnBridge()
        let executor = FakeTurnExecutor()

        executor.perform(bridge.begin(payload(attemptID: "A")), bridge: &bridge)
        XCTAssertEqual(executor.threadStartRequests, 1)
        guard let requestID = executor.lastThreadRequestID else {
            return XCTFail("no thread/start request was made")
        }

        // The backend answers `thread/start` with an error.
        let action = CodexWindowTurnFailureRouter.action(
            for: .threadStart,
            backendMessage: "Invalid model",
            bridge: &bridge
        )
        executor.perform(action, bridge: &bridge)

        XCTAssertTrue(bridge.isIdle, "the attempt must be released after an error")
        XCTAssertEqual(executor.deliveredResults, [.rejected(.modelRejected)])
        XCTAssertTrue(executor.interrupts.isEmpty, "a refused thread has nothing to interrupt")
        _ = requestID

        // A later retry must reach the transport again instead of being refused.
        let retry = bridge.begin(payload(attemptID: "B"))
        guard case let .sendThread(retryPayload) = retry else {
            return XCTFail("retry was refused: \(retry)")
        }
        XCTAssertEqual(retryPayload.attemptID, "B")

        executor.perform(retry, bridge: &bridge)
        XCTAssertEqual(
            executor.threadStartRequests,
            2,
            "a genuine retry must issue a second thread/start"
        )
    }

    func testTurnStartErrorReleasesTheAttemptAndAllowsARetry() {
        var bridge = CodexWindowTurnBridge()
        let executor = FakeTurnExecutor()

        executor.perform(bridge.begin(payload(attemptID: "A")), bridge: &bridge)
        guard let threadRequestID = executor.lastThreadRequestID else {
            return XCTFail("no thread/start request was made")
        }
        executor.perform(
            bridge.receiveThreadReply(
                requestID: threadRequestID,
                generation: 1,
                threadID: "thread-A",
                modelProvider: "openai"
            ),
            bridge: &bridge
        )
        XCTAssertEqual(executor.turnStartRequests, 1)

        let action = CodexWindowTurnFailureRouter.action(
            for: .turnStart,
            backendMessage: "model not supported",
            bridge: &bridge
        )
        executor.perform(action, bridge: &bridge)

        XCTAssertTrue(bridge.isIdle)
        XCTAssertEqual(executor.deliveredResults, [.rejected(.modelRejected)])
        XCTAssertEqual(
            executor.interrupts.map(\.threadID),
            ["thread-A"],
            "the attached thread must be interrupted on a live transport"
        )

        let retry = bridge.begin(payload(attemptID: "B"))
        guard case .sendThread = retry else {
            return XCTFail("retry was refused: \(retry)")
        }
        executor.perform(retry, bridge: &bridge)
        XCTAssertEqual(executor.threadStartRequests, 2)
    }

    func testAnErrorIsDeliveredExactlyOnce() {
        var bridge = CodexWindowTurnBridge()
        let executor = FakeTurnExecutor()

        _ = bridge.begin(payload(attemptID: "A"))
        executor.perform(
            CodexWindowTurnFailureRouter.action(for: .threadStart, bridge: &bridge),
            bridge: &bridge
        )
        // A duplicate error for the same attempt must not report twice.
        executor.perform(
            CodexWindowTurnFailureRouter.action(for: .threadStart, bridge: &bridge),
            bridge: &bridge
        )

        XCTAssertEqual(executor.deliveredResults.count, 1)
    }

    // MARK: - Process exit and recovery

    func testProcessExitReleasesTheAttemptAndKeepsUnknownDelivery() {
        var bridge = CodexWindowTurnBridge()
        let executor = FakeTurnExecutor()

        executor.perform(bridge.begin(payload(attemptID: "A")), bridge: &bridge)
        executor.transportCanReceiveRequests = false

        executor.perform(
            CodexWindowTurnFailureRouter.action(for: .processExited, bridge: &bridge),
            bridge: &bridge
        )

        XCTAssertTrue(bridge.isIdle)
        XCTAssertEqual(executor.deliveredResults, [.undetermined(.connectionLost)])
        XCTAssertTrue(
            executor.interrupts.isEmpty,
            "a dead App Server cannot acknowledge an interrupt"
        )
    }

    func testTransportResetKeepsUnknownDeliveryAfterTurnDispatch() {
        var bridge = CodexWindowTurnBridge()
        let executor = FakeTurnExecutor()

        executor.perform(bridge.begin(payload(attemptID: "A")), bridge: &bridge)
        guard let threadRequestID = executor.lastThreadRequestID else {
            return XCTFail("no thread/start request")
        }
        executor.perform(
            bridge.receiveThreadReply(
                requestID: threadRequestID,
                generation: 1,
                threadID: "thread-A",
                modelProvider: "openai"
            ),
            bridge: &bridge
        )

        executor.perform(
            CodexWindowTurnFailureRouter.action(for: .transportReset, bridge: &bridge),
            bridge: &bridge
        )

        XCTAssertTrue(bridge.isIdle)
        XCTAssertEqual(
            executor.deliveredResults,
            [.undetermined(.connectionLost)],
            "a dispatched turn must never be reclassified as not sent"
        )
    }

    func testRecoveredTransportCanStartANewAttempt() {
        var bridge = CodexWindowTurnBridge()
        let executor = FakeTurnExecutor()

        executor.perform(bridge.begin(payload(attemptID: "A")), bridge: &bridge)
        executor.perform(
            CodexWindowTurnFailureRouter.action(for: .processExited, bridge: &bridge),
            bridge: &bridge
        )

        // The App Server came back.
        executor.transportCanReceiveRequests = true
        let retry = bridge.begin(payload(attemptID: "B", generation: 2))
        guard case let .sendThread(payload) = retry else {
            return XCTFail("recovered transport was refused: \(retry)")
        }
        XCTAssertEqual(payload.attemptID, "B")
        executor.perform(retry, bridge: &bridge)

        XCTAssertEqual(executor.threadStartRequests, 2)
    }

    // MARK: - Classification

    func testBackendErrorMessagesAreClassified() {
        func code(_ message: String) -> UsageWindowStartFailureCode {
            CodexWindowTurnFailureRouter.failureCode(forBackendMessage: message)
        }

        XCTAssertEqual(code("Invalid model: gpt-5"), .modelRejected)
        XCTAssertEqual(code("not logged in"), .notAuthenticated)
        XCTAssertEqual(code("Unauthorized (401)"), .notAuthenticated)
        XCTAssertEqual(code("database is locked"), .transportError)
    }

    func testAccountBoundaryStillWinsOverAnAnsweredError() {
        var bridge = CodexWindowTurnBridge()
        let executor = FakeTurnExecutor()

        executor.perform(bridge.begin(payload(attemptID: "A")), bridge: &bridge)
        executor.perform(bridge.accountBoundary(), bridge: &bridge)

        // The attempt is gone, so a later error for it changes nothing.
        executor.perform(
            CodexWindowTurnFailureRouter.action(for: .threadStart, bridge: &bridge),
            bridge: &bridge
        )

        XCTAssertTrue(bridge.isIdle)
        XCTAssertEqual(executor.deliveredResults.count, 1)
    }
}
