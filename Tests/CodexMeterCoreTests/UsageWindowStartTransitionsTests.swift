import XCTest
@testable import CodexMeterCore

final class UsageWindowStartTransitionsTests: XCTestCase {
    private let now = WindowStartFixtures.base

    // MARK: - Reservation

    func testReservationOpensTheEpisodeBeforeDispatch() {
        var state = UsageWindowStartState.empty

        UsageWindowStartTransitions.reserve(
            &state,
            attemptID: "attempt-1",
            now: now,
            confirmationDelay: 90,
            windowIdentity: "codex:300"
        )

        XCTAssertEqual(state.phase, .sending)
        XCTAssertEqual(state.attemptID, "attempt-1")
        XCTAssertEqual(state.reservedAt, now)
        XCTAssertEqual(state.confirmationDeadline, now.addingTimeInterval(90))
        XCTAssertEqual(state.targetWindowIdentity, "codex:300")
        XCTAssertTrue(state.episodeOpen)
        XCTAssertFalse(state.windowObservedRunning)
        XCTAssertTrue(UsageWindowStartTransitions.hasUnresolvedAttempt(state))
    }

    func testReservationResetsAPreviousWindowsObservationFlag() {
        var state = UsageWindowStartState.empty
        state.episodeOpen = true
        state.windowObservedRunning = true

        UsageWindowStartTransitions.reserve(
            &state,
            attemptID: "attempt-2",
            now: now,
            confirmationDelay: 90,
            windowIdentity: "codex:300"
        )

        XCTAssertFalse(state.windowObservedRunning)
    }

    // MARK: - Outcomes

    func testDeliveredTurnStaysAwaitingConfirmation() {
        var state = reservedState()
        UsageWindowStartTransitions.apply(.delivered(turnID: "t", modelProvider: "openai"), to: &state, now: now)

        XCTAssertEqual(state.phase, .awaitingConfirmation)
        XCTAssertTrue(state.episodeOpen)
        XCTAssertNil(state.lastOutcomeCode)
        XCTAssertEqual(state.lastSentAt, now)
        XCTAssertTrue(UsageWindowStartTransitions.hasUnresolvedAttempt(state))
    }

    func testProvableRefusalClosesTheEpisodeButKeepsTheCooldown() {
        var state = reservedState()
        UsageWindowStartTransitions.apply(.failed(.modelRejected), to: &state, now: now)

        XCTAssertEqual(state.phase, .failed)
        XCTAssertFalse(state.episodeOpen)
        XCTAssertEqual(state.lastOutcomeCode, .failed)
        XCTAssertEqual(state.lastFailureCode, .modelRejected)
        XCTAssertNil(state.confirmationDeadline)
        // The timestamp survives so a rejected model is not retried every minute.
        XCTAssertEqual(state.lastSentAt, now)
    }

    func testUnknownDeliveryKeepsTheEpisodeOpen() {
        var state = reservedState()
        UsageWindowStartTransitions.apply(.deliveryUnknown(.timeout), to: &state, now: now)

        XCTAssertEqual(state.phase, .failed)
        XCTAssertTrue(state.episodeOpen)
        XCTAssertEqual(state.lastOutcomeCode, .deliveryUnknown)
        XCTAssertEqual(state.lastFailureCode, .timeout)
        XCTAssertTrue(UsageWindowStartTransitions.hasUnresolvedAttempt(state))
    }

    func testCancelledDeliveryIsAlsoUnknown() {
        var state = reservedState()
        UsageWindowStartTransitions.apply(.deliveryUnknown(.cancelled), to: &state, now: now)
        XCTAssertEqual(state.lastOutcomeCode, .deliveryUnknown)
        XCTAssertTrue(state.episodeOpen)
    }

    // MARK: - Reconciliation

    func testObservingTheWindowRunningConfirms() {
        var state = deliveredState()

        let changed = UsageWindowStartTransitions.reconcile(
            activity: .active,
            state: &state,
            now: now
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(state.phase, .confirmed)
        XCTAssertEqual(state.lastOutcomeCode, .confirmed)
        XCTAssertEqual(state.lastConfirmedAt, now)
        XCTAssertNil(state.confirmationDeadline)
        XCTAssertTrue(state.windowObservedRunning)
    }

    func testObservingTheWindowEndAllowsANewEpisode() {
        var state = deliveredState()
        UsageWindowStartTransitions.reconcile(activity: .active, state: &state, now: now)

        UsageWindowStartTransitions.reconcile(
            activity: .idle,
            state: &state,
            now: now.addingTimeInterval(6 * 3_600)
        )

        XCTAssertFalse(state.episodeOpen)
        XCTAssertFalse(state.windowObservedRunning)
        XCTAssertFalse(UsageWindowStartTransitions.hasUnresolvedAttempt(state))
    }

    func testIdleWithoutEverSeeingTheWindowDoesNotCloseTheEpisode() {
        var state = deliveredState()

        let changed = UsageWindowStartTransitions.reconcile(
            activity: .idle,
            state: &state,
            now: now
        )

        XCTAssertFalse(changed)
        XCTAssertTrue(state.episodeOpen)
    }

    func testUnknownActivityNeverChangesAnything() {
        var state = deliveredState()
        let changed = UsageWindowStartTransitions.reconcile(
            activity: .unknown,
            state: &state,
            now: now
        )
        XCTAssertFalse(changed)
        XCTAssertTrue(state.episodeOpen)
        XCTAssertEqual(state.phase, .awaitingConfirmation)
    }

    func testRepeatedActiveObservationsAreIdempotent() {
        var state = deliveredState()
        UsageWindowStartTransitions.reconcile(activity: .active, state: &state, now: now)

        let changed = UsageWindowStartTransitions.reconcile(
            activity: .active,
            state: &state,
            now: now.addingTimeInterval(60)
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(state.lastConfirmedAt, now)
    }

    // MARK: - Confirmation

    func testConfirmingASettledDeadlineMarksConfirmed() {
        var state = deliveredState()
        UsageWindowStartTransitions.confirm(&state, confirmed: true, now: now)

        XCTAssertEqual(state.phase, .confirmed)
        XCTAssertEqual(state.lastOutcomeCode, .confirmed)
        XCTAssertNil(state.confirmationDeadline)
        XCTAssertTrue(state.windowObservedRunning)
    }

    func testUnconfirmedKeepsTheEpisodeOpen() {
        var state = deliveredState()
        UsageWindowStartTransitions.confirm(&state, confirmed: false, now: now)

        XCTAssertEqual(state.phase, .unconfirmed)
        XCTAssertEqual(state.lastOutcomeCode, .unconfirmed)
        XCTAssertTrue(state.episodeOpen)
        XCTAssertNil(state.confirmationDeadline)
        XCTAssertTrue(UsageWindowStartTransitions.hasUnresolvedAttempt(state))
    }

    // MARK: - Clearing

    func testClearingProtectionKeepsTheCooldownTimestamp() {
        var state = reservedState()
        UsageWindowStartTransitions.apply(.deliveryUnknown(.timeout), to: &state, now: now)

        UsageWindowStartTransitions.clearProtection(&state)

        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(state.episodeOpen)
        XCTAssertNil(state.lastOutcomeCode)
        XCTAssertNil(state.attemptID)
        XCTAssertEqual(state.lastSentAt, now)
        XCTAssertFalse(UsageWindowStartTransitions.hasUnresolvedAttempt(state))
    }

    // MARK: - Helpers

    private func reservedState() -> UsageWindowStartState {
        var state = UsageWindowStartState.empty
        UsageWindowStartTransitions.reserve(
            &state,
            attemptID: "attempt",
            now: now,
            confirmationDelay: 90,
            windowIdentity: "codex:300"
        )
        return state
    }

    private func deliveredState() -> UsageWindowStartState {
        var state = reservedState()
        UsageWindowStartTransitions.apply(
            .delivered(turnID: "turn", modelProvider: "openai"),
            to: &state,
            now: now
        )
        return state
    }
}
