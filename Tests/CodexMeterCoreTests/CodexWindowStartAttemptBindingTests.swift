import XCTest
@testable import CodexMeterCore

/// Keeps every callback so a test can answer an abandoned attempt after a newer
/// attempt has already started.
private final class CallbackKeepingTransport: WindowStartTransport {
    private let lock = NSLock()
    private var entries: [(request: WindowStartRequest, completion: (WindowStartTransportResult) -> Void)] = []
    private var cancels: [String] = []
    /// Ordered log of what the transport and the caller's completions did, so a
    /// test can assert the interrupt really preceded the replacement.
    private var log: [String] = []
    /// Models the real transport: only the attempt that currently holds the slot
    /// can be interrupted.
    private var liveAttemptID: String?

    func startEphemeralTurn(
        _ request: WindowStartRequest,
        completion: @escaping (WindowStartTransportResult) -> Void
    ) {
        lock.lock()
        entries.append((request, completion))
        liveAttemptID = request.attemptID
        log.append("start:\(request.attemptID)")
        lock.unlock()
    }

    func cancelPendingTurn(attemptID: String) {
        lock.lock()
        cancels.append(attemptID)
        log.append("cancel:\(attemptID)")
        if liveAttemptID == attemptID {
            liveAttemptID = nil
            log.append("interrupted:\(attemptID)")
        } else {
            log.append("interrupt-missed:\(attemptID)")
        }
        lock.unlock()
    }

    func recordCallerEvent(_ event: String) {
        lock.lock()
        log.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var liveAttempt: String? {
        lock.lock()
        defer { lock.unlock() }
        return liveAttemptID
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    var cancelledAttemptIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels.count
    }

    func respond(toCall index: Int, with result: WindowStartTransportResult) {
        lock.lock()
        let completion = entries[index].completion
        lock.unlock()
        completion(result)
    }
}

final class CodexWindowStartAttemptBindingTests: XCTestCase {
    private func request(timeout: TimeInterval = 5) -> WindowStartRequest {
        WindowStartRequest(modelID: "gpt-5", reasoningEffort: "low", timeout: timeout)
    }

    func testLateCallbackFromACancelledAttemptCannotCompleteTheReplacement() {
        let transport = CallbackKeepingTransport()
        let runner = CodexWindowStartRunner(transport: transport)

        var firstOutcome: WindowStartOutcome?
        runner.start(request()) { firstOutcome = $0 }
        runner.cancel()
        XCTAssertEqual(firstOutcome, .deliveryUnknown(.cancelled))

        let replacement = expectation(description: "replacement resolves once")
        var secondOutcome: WindowStartOutcome?
        runner.start(request()) { outcome in
            secondOutcome = outcome
            replacement.fulfill()
        }

        // The abandoned attempt's callback arrives after the replacement began.
        transport.respond(toCall: 0, with: .completed(turnID: "old-A", modelProvider: "openai"))
        XCTAssertNil(secondOutcome, "a late callback must not complete the new attempt")

        transport.respond(toCall: 1, with: .completed(turnID: "new-B", modelProvider: "openai"))
        wait(for: [replacement], timeout: 5)

        XCTAssertEqual(secondOutcome, .delivered(turnID: "new-B", modelProvider: "openai"))
        XCTAssertEqual(transport.callCount, 2)
    }

    func testCancelledAttemptsTimeoutCannotResolveTheReplacement() {
        let transport = CallbackKeepingTransport()
        let runner = CodexWindowStartRunner(transport: transport)

        // A is armed with a very short deadline and is cancelled immediately.
        var firstOutcome: WindowStartOutcome?
        runner.start(request(timeout: 0.05)) { firstOutcome = $0 }
        runner.cancel()
        XCTAssertEqual(firstOutcome, .deliveryUnknown(.cancelled))

        let replacement = expectation(description: "replacement resolves once")
        replacement.isInverted = true
        var secondOutcome: WindowStartOutcome?
        runner.start(request(timeout: 5)) { outcome in
            secondOutcome = outcome
            replacement.fulfill()
        }

        // Wait past A's original deadline: its timeout must not settle B.
        wait(for: [replacement], timeout: 0.4)
        XCTAssertNil(secondOutcome)
        XCTAssertTrue(runner.isRunning)

        let finished = expectation(description: "replacement completes")
        transport.respond(toCall: 1, with: .completed(turnID: "new-B", modelProvider: "openai"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { finished.fulfill() }
        wait(for: [finished], timeout: 5)

        XCTAssertEqual(secondOutcome, .delivered(turnID: "new-B", modelProvider: "openai"))
    }

    func testOldTimeoutDoesNotInterruptTheNewAttemptsTransportCall() {
        let transport = CallbackKeepingTransport()
        let runner = CodexWindowStartRunner(transport: transport)

        runner.start(request(timeout: 0.05)) { _ in }
        runner.cancel()
        let cancelsAfterCancel = transport.cancelCount

        runner.start(request(timeout: 5)) { _ in }
        // Give the abandoned deadline time to fire.
        let settled = expectation(description: "waited")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(
            transport.cancelCount,
            cancelsAfterCancel,
            "the abandoned timeout must not interrupt the live attempt"
        )
    }

    // MARK: - RPC bookkeeping

    func testBookkeeperRejectsASecondConcurrentAttempt() {
        var bookkeeper = CodexTurnStartBookkeeper()
        XCTAssertTrue(bookkeeper.begin(attemptID: "A", generation: 1))
        XCTAssertFalse(bookkeeper.begin(attemptID: "B", generation: 1))
    }

    /// The bridge drops a reply by its request identifier before it ever reaches
    /// the attach step, so this asserts the source check that actually decides.
    func testLateThreadReplyFromAnAbandonedAttemptIsRefusedBySourceCheck() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "A", generation: 1)
        bookkeeper.recordThreadRequest(id: 10)
        XCTAssertEqual(bookkeeper.cancel(), [10])

        bookkeeper.begin(attemptID: "B", generation: 1)
        bookkeeper.recordThreadRequest(id: 20)

        // A's request identifier no longer belongs to the live attempt.
        XCTAssertFalse(bookkeeper.owns(requestID: 10))
        // B's does, and it attaches exactly one thread.
        XCTAssertTrue(bookkeeper.owns(requestID: 20))
        XCTAssertTrue(bookkeeper.acceptThreadStarted(threadID: "thread-B", modelProvider: "openai"))
        XCTAssertEqual(bookkeeper.active?.threadID, "thread-B")
        XCTAssertEqual(bookkeeper.active?.attemptID, "B")
    }

    // MARK: - Account generation gate

    func testThreadReplyFromAPreviousGenerationMustNotAdvance() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "A", generation: 1)
        bookkeeper.recordThreadRequest(id: 10)

        // The account switched between the request and its reply.
        XCTAssertTrue(bookkeeper.accepts(generation: 1))
        XCTAssertFalse(bookkeeper.accepts(generation: 2))

        // Abandoning it forgets the reply's identifier so it is dropped.
        XCTAssertEqual(bookkeeper.cancel(attemptID: "A"), [10])
        XCTAssertTrue(bookkeeper.isIdle)
    }

    func testDispatchedTurnIsDistinguishedFromAnUnsentThread() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "A", generation: 1)
        bookkeeper.recordThreadRequest(id: 10)
        XCTAssertFalse(bookkeeper.hasDispatchedTurn)

        bookkeeper.acceptThreadStarted(threadID: "thread-A", modelProvider: "openai")
        bookkeeper.recordTurnRequest(id: 11)
        XCTAssertTrue(bookkeeper.hasDispatchedTurn)
    }

    func testForeignCancelNeverClearsTheReplacement() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "B", generation: 2)

        XCTAssertEqual(bookkeeper.cancel(attemptID: "A"), [])
        XCTAssertEqual(bookkeeper.attemptID, "B")
        XCTAssertNil(bookkeeper.finishIfOwned(by: "A"))
        XCTAssertEqual(bookkeeper.finishIfOwned(by: "B")?.attemptID, "B")
        XCTAssertTrue(bookkeeper.isIdle)
    }

    // MARK: - Cancellation ordering

    /// A timeout completion is allowed to start a replacement immediately. The
    /// interrupt for the abandoned attempt must already have been delivered, so
    /// the replacement is never the target.
    func testTimeoutCompletionStartingAReplacementDoesNotCancelIt() {
        let transport = CallbackKeepingTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let started = expectation(description: "replacement started")
        var replacementOutcome: WindowStartOutcome?
        var didStartReplacement = false

        runner.start(
            WindowStartRequest(
                modelID: "gpt-5",
                reasoningEffort: "low",
                timeout: 0.05,
                attemptID: "A"
            )
        ) { outcome in
            guard case .deliveryUnknown(.timeout) = outcome else {
                started.fulfill()
                return
            }
            guard !didStartReplacement else {
                started.fulfill()
                return
            }
            didStartReplacement = true
            transport.recordCallerEvent("caller-starts:B")
            runner.start(
                WindowStartRequest(
                    modelID: "gpt-5",
                    reasoningEffort: "low",
                    timeout: 5,
                    attemptID: "B"
                )
            ) { replacementOutcome = $0 }
            started.fulfill()
        }

        wait(for: [started], timeout: 5)

        XCTAssertTrue(didStartReplacement)
        XCTAssertEqual(transport.cancelledAttemptIDs, ["A"], "the interrupt must name A")
        XCTAssertEqual(transport.liveAttempt, "B", "B must still own the transport slot")
        XCTAssertNil(replacementOutcome)
        XCTAssertTrue(runner.isRunning, "B must still be in flight")

        // The abandoned attempt must be interrupted before its completion is
        // allowed to authorize a replacement.
        let events = transport.events
        let cancelIndex = events.firstIndex(of: "interrupted:A")
        let callerIndex = events.firstIndex(of: "caller-starts:B")
        XCTAssertNotNil(cancelIndex, "A's transport call must actually be interrupted")
        XCTAssertNotNil(callerIndex)
        if let cancelIndex, let callerIndex {
            XCTAssertLessThan(cancelIndex, callerIndex, "interrupt must precede the replacement")
        }
    }

    func testAbandonedTimeoutCancelsOnlyItsOwnAttempt() {
        let transport = CallbackKeepingTransport()
        let runner = CodexWindowStartRunner(transport: transport)
        let timedOut = expectation(description: "A timed out")
        var resolved = false

        runner.start(
            WindowStartRequest(
                modelID: "gpt-5",
                reasoningEffort: "low",
                timeout: 0.05,
                attemptID: "A"
            )
        ) { _ in
            if !resolved {
                resolved = true
                timedOut.fulfill()
            }
        }
        wait(for: [timedOut], timeout: 5)

        runner.start(
            WindowStartRequest(
                modelID: "gpt-5",
                reasoningEffort: "low",
                timeout: 5,
                attemptID: "B"
            )
        ) { _ in }

        let waited = expectation(description: "waited")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waited.fulfill() }
        wait(for: [waited], timeout: 5)

        XCTAssertEqual(transport.cancelledAttemptIDs, ["A"])
        XCTAssertTrue(runner.isRunning)
    }

    func testCancelReturnsEveryOutstandingRequestID() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "A", generation: 3)
        bookkeeper.recordThreadRequest(id: 11)
        bookkeeper.acceptThreadStarted(threadID: "thread-A", modelProvider: "openai")
        bookkeeper.recordTurnRequest(id: 12)

        XCTAssertEqual(bookkeeper.cancel(), [11, 12])
        XCTAssertTrue(bookkeeper.isIdle)
        XCTAssertFalse(bookkeeper.owns(requestID: 11))
        XCTAssertFalse(bookkeeper.acceptThreadStarted(threadID: "x", modelProvider: nil))
    }

    func testTurnCannotStartBeforeAThreadIsAttached() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "A", generation: 1)

        XCTAssertFalse(bookkeeper.acceptTurnStarted(turnID: "turn-A"))
        bookkeeper.acceptThreadStarted(threadID: "thread-A", modelProvider: "openai")
        XCTAssertTrue(bookkeeper.acceptTurnStarted(turnID: "turn-A"))
        XCTAssertEqual(bookkeeper.active?.turnID, "turn-A")
    }

    func testCompletionMustNameThisAttemptsThreadAndTurn() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "A", generation: 1)
        bookkeeper.acceptThreadStarted(threadID: "thread-A", modelProvider: "openai")

        // The turn is not known yet, so any turn on the thread is accepted.
        XCTAssertTrue(bookkeeper.matchesCompletion(threadID: "thread-A", turnID: "turn-1"))
        XCTAssertFalse(bookkeeper.matchesCompletion(threadID: "thread-other", turnID: "turn-1"))

        bookkeeper.acceptTurnStarted(turnID: "turn-1")
        XCTAssertTrue(bookkeeper.matchesCompletion(threadID: "thread-A", turnID: "turn-1"))
        XCTAssertFalse(bookkeeper.matchesCompletion(threadID: "thread-A", turnID: "turn-2"))
        XCTAssertTrue(bookkeeper.matchesCompletion(threadID: "thread-A", turnID: nil))
    }

    func testFinishClearsTheSlotAndKeepsWhatWasRecorded() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "A", generation: 2)
        bookkeeper.acceptThreadStarted(threadID: "thread-A", modelProvider: "openai")
        bookkeeper.acceptTurnStarted(turnID: "turn-A")

        let finished = bookkeeper.finish()

        XCTAssertEqual(finished?.attemptID, "A")
        XCTAssertEqual(finished?.generation, 2)
        XCTAssertEqual(finished?.turnID, "turn-A")
        XCTAssertTrue(bookkeeper.isIdle)
    }

    func testOwningRequestIDsOnlyWhileTheAttemptIsActive() {
        var bookkeeper = CodexTurnStartBookkeeper()
        bookkeeper.begin(attemptID: "A", generation: 1)
        bookkeeper.recordThreadRequest(id: 7)
        bookkeeper.recordTurnRequest(id: 8)

        XCTAssertTrue(bookkeeper.owns(requestID: 7))
        XCTAssertTrue(bookkeeper.owns(requestID: 8))
        XCTAssertFalse(bookkeeper.owns(requestID: 9))
        bookkeeper.cancel()
        XCTAssertFalse(bookkeeper.owns(requestID: 7))
    }

    // MARK: - Notification routing

    func testWakeIsDeliveredByTheWorkspaceCenter() {
        // NSWorkspace posts on its own center, so observing it on the application
        // center never fires.
        XCTAssertEqual(UsageWindowSystemNotification.wake.centerKind, .workspace)
        XCTAssertEqual(UsageWindowSystemNotification.clockChange.centerKind, .application)
        XCTAssertEqual(UsageWindowSystemNotification.timeZoneChange.centerKind, .application)
    }
}
