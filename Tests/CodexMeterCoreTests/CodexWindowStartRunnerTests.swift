import XCTest
@testable import CodexMeterCore

/// Records what the runner asked for and lets a test answer on demand.
private final class FakeWindowStartTransport: WindowStartTransport {
    private let lock = NSLock()
    private(set) var requests: [WindowStartRequest] = []
    private(set) var cancelledAttemptIDs: [String] = []
    private var pending: ((WindowStartTransportResult) -> Void)?

    func startEphemeralTurn(
        _ request: WindowStartRequest,
        completion: @escaping (WindowStartTransportResult) -> Void
    ) {
        lock.lock()
        requests.append(request)
        pending = completion
        lock.unlock()
    }

    func cancelPendingTurn(attemptID: String) {
        lock.lock()
        cancelledAttemptIDs.append(attemptID)
        lock.unlock()
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelledAttemptIDs.count
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func respond(_ result: WindowStartTransportResult) {
        lock.lock()
        let completion = pending
        pending = nil
        lock.unlock()
        completion?(result)
    }
}

final class CodexWindowStartRunnerTests: XCTestCase {
    private func makeRequest(timeout: TimeInterval = 120) -> WindowStartRequest {
        WindowStartRequest(
            modelID: "gpt-5",
            reasoningEffort: "low",
            timeout: timeout
        )
    }

    private func run(
        _ transport: FakeWindowStartTransport,
        request: WindowStartRequest? = nil
    ) -> WindowStartOutcome {
        let runner = CodexWindowStartRunner(transport: transport)
        let expectation = expectation(description: "runner finished")
        var outcome: WindowStartOutcome?
        runner.start(request ?? makeRequest()) { result in
            outcome = result
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return outcome ?? .failed(.transportError)
    }

    func testCompletedTurnIsDeliveredButNotConfirmed() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let expectation = expectation(description: "finished")
        var outcome: WindowStartOutcome?

        runner.start(makeRequest()) { result in
            outcome = result
            expectation.fulfill()
        }
        transport.respond(.completed(turnID: "turn-1", modelProvider: "openai"))
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(outcome, .delivered(turnID: "turn-1", modelProvider: "openai"))
    }

    func testRequestShapeIsPassedThroughUnchanged() {
        let transport = FakeWindowStartTransport()
        _ = run(transport, request: makeRequest(timeout: 0.05))

        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(transport.requests.first?.modelID, "gpt-5")
        XCTAssertEqual(transport.requests.first?.reasoningEffort, "low")
        XCTAssertEqual(transport.requests.first?.prompt, WindowStartRequest.defaultPrompt)
    }

    func testBackendTurnFailureIsDeliveryUnknown() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let expectation = expectation(description: "finished")
        var outcome: WindowStartOutcome?

        runner.start(makeRequest()) { result in
            outcome = result
            expectation.fulfill()
        }
        transport.respond(.turnFailed(turnID: "turn-2", detail: "model overloaded"))
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(outcome, .deliveryUnknown(.turnFailed))
    }

    func testInterruptedTurnIsDeliveryUnknown() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let expectation = expectation(description: "finished")
        var outcome: WindowStartOutcome?

        runner.start(makeRequest()) { result in
            outcome = result
            expectation.fulfill()
        }
        transport.respond(.interrupted(turnID: "turn-3"))
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(outcome, .deliveryUnknown(.turnInterrupted))
    }

    func testRefusedRequestIsAFailure() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let expectation = expectation(description: "finished")
        var outcome: WindowStartOutcome?

        runner.start(makeRequest()) { result in
            outcome = result
            expectation.fulfill()
        }
        transport.respond(.rejected(.modelRejected))
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(outcome, .failed(.modelRejected))
    }

    func testUndeterminedResultKeepsProtection() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let expectation = expectation(description: "finished")
        var outcome: WindowStartOutcome?

        runner.start(makeRequest()) { result in
            outcome = result
            expectation.fulfill()
        }
        transport.respond(.undetermined(.connectionLost))
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(outcome, .deliveryUnknown(.connectionLost))
    }

    func testTimeoutInterruptsTheTurnAndKeepsProtection() {
        let transport = FakeWindowStartTransport()
        let outcome = run(transport, request: makeRequest(timeout: 0.05))

        XCTAssertEqual(outcome, .deliveryUnknown(.timeout))
        XCTAssertEqual(transport.cancelCount, 1)
    }

    func testLateCallbackAfterTimeoutIsIgnored() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let completion = expectation(description: "finished")
        var outcome: WindowStartOutcome?

        runner.start(makeRequest(timeout: 0.05)) { result in
            outcome = result
            completion.fulfill()
        }
        wait(for: [completion], timeout: 5)
        XCTAssertEqual(outcome, .deliveryUnknown(.timeout))

        // A duplicate resolution must not start a second completion.
        let secondExpectation = expectation(description: "no second completion")
        secondExpectation.isInverted = true
        transport.respond(.completed(turnID: "late", modelProvider: nil))
        wait(for: [secondExpectation], timeout: 0.2)
    }

    func testCancellationReportsUnknownDelivery() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let expectation = expectation(description: "finished")
        var outcome: WindowStartOutcome?

        runner.start(makeRequest()) { result in
            outcome = result
            expectation.fulfill()
        }
        runner.cancel()
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(outcome, .deliveryUnknown(.cancelled))
        XCTAssertEqual(transport.cancelCount, 1)
    }

    func testSecondRequestIsRefusedWithoutDispatching() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let first = expectation(description: "first")

        runner.start(makeRequest()) { _ in first.fulfill() }

        var secondOutcome: WindowStartOutcome?
        runner.start(makeRequest()) { secondOutcome = $0 }

        XCTAssertEqual(secondOutcome, .failed(.concurrentRequest))
        XCTAssertEqual(transport.callCount, 1)

        transport.respond(.completed(turnID: nil, modelProvider: nil))
        wait(for: [first], timeout: 5)
    }

    func testInvalidRequestNeverReachesTheTransport() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        var outcome: WindowStartOutcome?

        runner.start(
            WindowStartRequest(modelID: "  ", reasoningEffort: "low")
        ) { outcome = $0 }

        XCTAssertEqual(outcome, .failed(.transportError))
        XCTAssertEqual(transport.callCount, 0)
    }

    func testEmptyEffortIsRejected() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        var outcome: WindowStartOutcome?

        runner.start(WindowStartRequest(modelID: "gpt-5", reasoningEffort: "")) { outcome = $0 }

        XCTAssertEqual(outcome, .failed(.transportError))
        XCTAssertEqual(transport.callCount, 0)
    }

    func testRunnerIsIdleAgainAfterCompletion() {
        let transport = FakeWindowStartTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let expectation = expectation(description: "finished")

        runner.start(makeRequest()) { _ in expectation.fulfill() }
        XCTAssertTrue(runner.isRunning)
        transport.respond(.completed(turnID: nil, modelProvider: nil))
        wait(for: [expectation], timeout: 5)

        XCTAssertFalse(runner.isRunning)
    }
}
