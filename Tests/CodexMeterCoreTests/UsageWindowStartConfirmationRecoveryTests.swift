import XCTest
@testable import CodexMeterCore

final class UsageWindowStartConfirmationRecoveryTests: XCTestCase {
    private let sentAt = WindowStartFixtures.base

    private func deliveredState() -> UsageWindowStartState {
        var state = UsageWindowStartState.empty
        UsageWindowStartTransitions.reserve(
            &state,
            attemptID: "recovery-attempt",
            now: sentAt,
            confirmationDelay: UsageWindowStartSchedule.confirmationDelay,
            windowIdentity: "codex:300"
        )
        UsageWindowStartTransitions.apply(
            .delivered(turnID: "recovery-turn", modelProvider: "openai"),
            to: &state,
            now: sentAt
        )
        return state
    }

    func testPeriodicIdleReadSettlesAfterOutageWithAutomationDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfirmationRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageWindowStartStore(directoryURL: directory)
        let key = WindowStartFixtures.chatgptKey
        let initial = deliveredState()
        try store.transaction { document in
            var record = document.record(for: key)
            record.settings = .defaultValue
            record.state = initial
            record.updatedAt = sentAt
            document.accounts[key] = record
        }

        // Recovery arrives after every extra confirmation retry could have
        // expired. This is an ordinary observation, not a new start request.
        let recoveredAt = sentAt.addingTimeInterval(3_600)
        let result = UsageWindowStartWrites.reconcile(
            activity: .idle,
            store: store,
            accountKey: key,
            now: recoveredAt,
            observedAt: recoveredAt
        )
        guard case let .written(state) = result else {
            return XCTFail("expected confirmation recovery, got \(result)")
        }
        XCTAssertEqual(state.phase, .unconfirmed)
        XCTAssertEqual(state.lastOutcomeCode, .unconfirmed)
        XCTAssertNil(state.confirmationDeadline)
        XCTAssertEqual(state.attemptID, initial.attemptID)
        XCTAssertEqual(state.lastSentAt, sentAt)
        XCTAssertTrue(state.episodeOpen)
        XCTAssertTrue(state.blocksNewAttempt)

        let persisted = try store.snapshot().record(for: key)
        XCTAssertFalse(persisted.settings.autoStartEnabled)
        XCTAssertEqual(persisted.state, state)

        let input = WindowStartFixtures.input(
            state: state,
            now: recoveredAt,
            trigger: .manual
        )
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(input).decision,
            .wait(.sameEpisodeAlreadySent),
            "settling a confirmation must never authorize another send"
        )
    }

    func testReadBeforeDeadlineDoesNotSettleConfirmation() {
        var state = deliveredState()
        let beforeDeadline = sentAt.addingTimeInterval(89)
        XCTAssertFalse(UsageWindowStartTransitions.reconcile(
            activity: .idle,
            state: &state,
            now: beforeDeadline,
            observedAt: beforeDeadline
        ))
        XCTAssertEqual(state.phase, .awaitingConfirmation)
    }

    func testCachedReadTakenBeforeDeadlineCannotSettleLater() {
        var state = deliveredState()
        XCTAssertFalse(UsageWindowStartTransitions.reconcile(
            activity: .idle,
            state: &state,
            now: sentAt.addingTimeInterval(100),
            observedAt: sentAt.addingTimeInterval(89)
        ))
        XCTAssertEqual(state.phase, .awaitingConfirmation)
    }

    func testStaleReadAfterDeadlineDoesNotSettleConfirmation() {
        var state = deliveredState()
        XCTAssertFalse(UsageWindowStartTransitions.reconcile(
            activity: .idle,
            state: &state,
            now: sentAt.addingTimeInterval(3_600),
            observedAt: sentAt.addingTimeInterval(3_539)
        ))
        XCTAssertEqual(state.phase, .awaitingConfirmation)
    }

    func testRecoveredActiveReadConfirmsWithoutClearingProtection() {
        var state = deliveredState()
        let recoveredAt = sentAt.addingTimeInterval(3_600)
        XCTAssertTrue(UsageWindowStartTransitions.reconcile(
            activity: .active,
            state: &state,
            now: recoveredAt,
            observedAt: recoveredAt
        ))
        XCTAssertEqual(state.phase, .confirmed)
        XCTAssertTrue(state.windowObservedRunning)
        XCTAssertTrue(state.episodeOpen)
    }

    func testRepeatedIdleReadDoesNotRewriteSettledResult() {
        var state = deliveredState()
        let recoveredAt = sentAt.addingTimeInterval(3_600)
        UsageWindowStartTransitions.reconcile(
            activity: .idle,
            state: &state,
            now: recoveredAt,
            observedAt: recoveredAt
        )
        let settled = state
        XCTAssertFalse(UsageWindowStartTransitions.reconcile(
            activity: .idle,
            state: &state,
            now: recoveredAt.addingTimeInterval(60),
            observedAt: recoveredAt.addingTimeInterval(60)
        ))
        XCTAssertEqual(state, settled)
    }
}
