import XCTest
@testable import CodexMeterCore

/// Combines the store, the transitions, the policy, and the schedule the way the
/// coordinator does, so crash and restart paths are covered without a running
/// App Server.
final class UsageWindowStartRecoveryTests: XCTestCase {
    private let now = WindowStartFixtures.base
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStartRecovery-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    func testCrashAfterReservationDoesNotSendAgainOnRelaunch() throws {
        let store = UsageWindowStartStore(directoryURL: directory)
        let attemptID = UUID().uuidString

        // The app reserved, then died before the runner answered.
        try store.transaction { document in
            var record = document.record(for: WindowStartFixtures.chatgptKey)
            record.settings = WindowStartFixtures.settings()
            UsageWindowStartTransitions.reserve(
                &record.state,
                attemptID: attemptID,
                now: now,
                confirmationDelay: UsageWindowStartSchedule.confirmationDelay,
                windowIdentity: "codex:300"
            )
            record.updatedAt = now
            document.accounts[WindowStartFixtures.chatgptKey] = record
        }

        // Relaunch reads the record back and evaluates the same idle window.
        let relaunched = UsageWindowStartStore(directoryURL: directory)
        let record = try relaunched.snapshot().record(for: WindowStartFixtures.chatgptKey)
        let evaluation = UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(
            state: record.state
        ))

        XCTAssertTrue(record.state.episodeOpen)
        XCTAssertEqual(record.state.attemptID, attemptID)
        XCTAssertEqual(evaluation.decision, .wait(.confirmationPending))
    }

    func testCrashAfterSendKeepsTheConfirmationDeadlineOnDisk() throws {
        let store = UsageWindowStartStore(directoryURL: directory)

        try store.transaction { document in
            var record = document.record(for: WindowStartFixtures.chatgptKey)
            record.settings = WindowStartFixtures.settings()
            UsageWindowStartTransitions.reserve(
                &record.state,
                attemptID: "attempt",
                now: now,
                confirmationDelay: 90,
                windowIdentity: "codex:300"
            )
            UsageWindowStartTransitions.apply(
                .delivered(turnID: "turn", modelProvider: "openai"),
                to: &record.state,
                now: now
            )
            record.updatedAt = now
            document.accounts[WindowStartFixtures.chatgptKey] = record
        }

        let record = try UsageWindowStartStore(directoryURL: directory)
            .snapshot()
            .record(for: WindowStartFixtures.chatgptKey)

        XCTAssertEqual(record.state.phase, .awaitingConfirmation)
        XCTAssertEqual(record.state.confirmationDeadline, now.addingTimeInterval(90))
        XCTAssertTrue(UsageWindowStartTransitions.hasUnresolvedAttempt(record.state))

        // The stored deadline is still what schedules the next look.
        let deadline = UsageWindowStartSchedule.nextDeadline(
            observation: WindowStartFixtures.idleObservation(),
            settings: record.settings,
            state: record.state,
            now: now,
            calendar: WindowStartFixtures.utcCalendar
        )
        XCTAssertEqual(deadline?.reason, .confirmation)
        XCTAssertEqual(deadline?.date, now.addingTimeInterval(90))
    }

    func testUnknownDeliverySurvivesARestartAndBlocks() throws {
        let store = UsageWindowStartStore(directoryURL: directory)

        try store.transaction { document in
            var record = document.record(for: WindowStartFixtures.chatgptKey)
            record.settings = WindowStartFixtures.settings()
            UsageWindowStartTransitions.reserve(
                &record.state,
                attemptID: "attempt",
                now: now,
                confirmationDelay: 90,
                windowIdentity: "codex:300"
            )
            UsageWindowStartTransitions.apply(
                .deliveryUnknown(.timeout),
                to: &record.state,
                now: now
            )
            record.updatedAt = now
            document.accounts[WindowStartFixtures.chatgptKey] = record
        }

        let record = try UsageWindowStartStore(directoryURL: directory)
            .snapshot()
            .record(for: WindowStartFixtures.chatgptKey)
        let evaluation = UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(
            state: record.state,
            // Even hours later, a cooldown alone must not authorize a resend.
            now: now.addingTimeInterval(4 * 3_600)
        ))

        XCTAssertEqual(evaluation.decision, .blocked(.previousDeliveryUnknown))
    }

    func testClearingProtectionFromTheSettingsPathAllowsOneLaterAttempt() throws {
        let store = UsageWindowStartStore(directoryURL: directory)

        try store.transaction { document in
            var record = document.record(for: WindowStartFixtures.chatgptKey)
            record.settings = WindowStartFixtures.settings()
            UsageWindowStartTransitions.reserve(
                &record.state,
                attemptID: "attempt",
                now: now,
                confirmationDelay: 90,
                windowIdentity: "codex:300"
            )
            UsageWindowStartTransitions.apply(
                .deliveryUnknown(.connectionLost),
                to: &record.state,
                now: now
            )
            UsageWindowStartTransitions.clearProtection(&record.state)
            record.updatedAt = now
            document.accounts[WindowStartFixtures.chatgptKey] = record
        }

        let record = try UsageWindowStartStore(directoryURL: directory)
            .snapshot()
            .record(for: WindowStartFixtures.chatgptKey)

        // Still inside the 30-minute cooldown.
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(
                state: record.state,
                now: now.addingTimeInterval(5 * 60)
            )).decision,
            .wait(.coolingDown)
        )
        // Once the cooldown has passed the entry is clear again.
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(
                state: record.state,
                now: now.addingTimeInterval(31 * 60)
            )).decision,
            .start
        )
    }

    func testOnlyOneInstanceCanTransactAtATime() throws {
        let first = UsageWindowStartStore(directoryURL: directory)
        let second = UsageWindowStartStore(directoryURL: directory)

        try first.transaction { _ in
            XCTAssertThrowsError(
                try second.transaction { document in
                    document.accounts["chatgpt:other"] = .empty(at: now)
                }
            ) { error in
                XCTAssertEqual(error as? UsageWindowStartStoreError, .lockUnavailable)
            }
        }
    }
}
