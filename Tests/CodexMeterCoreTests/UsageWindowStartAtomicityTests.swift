import XCTest
@testable import CodexMeterCore

/// Regression coverage for the review's blocking findings: the reservation must
/// be an atomic check-and-occupy, and a late actor must never land on a newer
/// attempt.
final class UsageWindowStartAtomicityTests: XCTestCase {
    private let now = WindowStartFixtures.base
    private var directory: URL!
    private var stores: [UsageWindowStartStore] = []

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowStartAtomicity-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    // MARK: - Cross-instance reservation

    /// Two copies that both observed the same idle snapshot must produce exactly
    /// one reservation. Before the decision moved inside the transaction both
    /// copies reserved and both sent.
    func testTwoInstancesWithTheSameStaleSnapshotReserveOnlyOnce() throws {
        let first = UsageWindowStartStore(directoryURL: directory)
        let second = UsageWindowStartStore(directoryURL: directory)

        // Both instances enable automatic start and read the same idle window.
        for store in [first, second] {
            try store.transaction { document in
                var record = document.record(for: WindowStartFixtures.chatgptKey)
                record.settings = WindowStartFixtures.settings()
                record.updatedAt = self.now
                document.accounts[WindowStartFixtures.chatgptKey] = record
            }
        }

        let request = reservationRequest()

        // A reserves, then B tries with the same stale snapshot after A's lock
        // has already been released.
        let firstOutcome = UsageWindowStartReserver.reserve(
            store: first,
            request: request,
            attemptID: "attempt-A"
        )
        let secondOutcome = UsageWindowStartReserver.reserve(
            store: second,
            request: request,
            attemptID: "attempt-B"
        )

        switch firstOutcome {
        case let .reserved(attemptID, _, _):
            XCTAssertEqual(attemptID, "attempt-A")
        default:
            XCTFail("the first instance should have reserved, got \(firstOutcome)")
        }
        XCTAssertEqual(secondOutcome, .rejected(.confirmationPending))
    }

    func testReservationRecordsTheAttemptThatOwnsTheDiskState() throws {
        let store = populatedStore()

        let outcome = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(),
            attemptID: "attempt-A"
        )

        guard case let .reserved(_, state, _) = outcome else {
            return XCTFail("expected a reservation, got \(outcome)")
        }
        XCTAssertEqual(state.attemptID, "attempt-A")
        XCTAssertEqual(state.phase, .sending)
        XCTAssertTrue(state.episodeOpen)

        let persisted = try store.snapshot().record(for: WindowStartFixtures.chatgptKey).state
        XCTAssertEqual(persisted.attemptID, "attempt-A")
        XCTAssertEqual(persisted.phase, .sending)
    }

    /// The disk record wins over the caller's copy, so a stale in-memory
    /// cooldown cannot authorize a send that the persisted state forbids.
    func testReservationUsesThePersistedCooldownNotTheCallersCopy() throws {
        let store = populatedStore()

        try store.transaction { document in
            var record = document.record(for: WindowStartFixtures.chatgptKey)
            record.state.lastSentAt = self.now.addingTimeInterval(-60)
            record.state.phase = .confirmed
            record.updatedAt = self.now
            document.accounts[WindowStartFixtures.chatgptKey] = record
        }

        let outcome = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(),
            attemptID: "attempt-A"
        )

        XCTAssertEqual(outcome, .rejected(.coolingDown))
    }

    func testReservationUsesPersistedSettingsNotTheCallersCopy() throws {
        let store = populatedStore()

        try store.transaction { document in
            var record = document.record(for: WindowStartFixtures.chatgptKey)
            record.settings.autoStartEnabled = false
            record.updatedAt = self.now
            document.accounts[WindowStartFixtures.chatgptKey] = record
        }

        // The caller still believes automatic start is on.
        let outcome = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(),
            attemptID: "attempt-A"
        )

        XCTAssertEqual(outcome, .rejected(.autoStartDisabled))
    }

    func testReservationReportsLockUnavailability() throws {
        let holder = populatedStore()
        let contender = UsageWindowStartStore(directoryURL: directory)

        try holder.transaction { _ in
            let outcome = UsageWindowStartReserver.reserve(
                store: contender,
                request: self.reservationRequest(),
                attemptID: "attempt-B"
            )
            XCTAssertEqual(outcome, .unavailable(.lockUnavailable))
        }
    }

    /// The reserver must compare the observation against the account the app is
    /// actually signed in as, not against the observation itself.
    func testObservationFromAPreviousGenerationIsRejected() throws {
        let store = populatedStore()

        let outcome = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(currentGeneration: 2),
            attemptID: "attempt-A"
        )

        XCTAssertEqual(outcome, .rejected(.accountChanged))
        let persisted = try store.snapshot().record(for: WindowStartFixtures.chatgptKey).state
        XCTAssertEqual(persisted.phase, .idle, "nothing may be reserved for a stale account")
    }

    func testStaleAccountTypeIsRejected() throws {
        let store = populatedStore()
        var request = reservationRequest()
        request = UsageWindowStartReservationRequest(
            accountKey: request.accountKey,
            observation: request.observation,
            previousObservation: request.previousObservation,
            currentAccountGeneration: request.currentAccountGeneration,
            currentAccountType: "apiKey",
            models: request.models,
            now: request.now,
            calendar: request.calendar,
            trigger: request.trigger,
            isPreviewMode: request.isPreviewMode
        )

        XCTAssertEqual(
            UsageWindowStartReserver.reserve(store: store, request: request, attemptID: "A"),
            .rejected(.unsupportedAccountType)
        )
    }

    // MARK: - Attempt-scoped writes

    func testLateOutcomeFromACancelledAttemptIsDropped() throws {
        let store = populatedStore()

        guard case let .reserved(firstID, _, _) = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(),
            attemptID: "attempt-A"
        ) else {
            return XCTFail("first reservation failed")
        }

        // The first attempt is abandoned, the user clears its protection, and a
        // second attempt takes the slot once the cooldown has passed.
        UsageWindowStartWrites.applySendOutcome(
            .deliveryUnknown(.timeout),
            attemptID: firstID,
            store: store,
            accountKey: WindowStartFixtures.chatgptKey,
            now: now
        )
        UsageWindowStartWrites.clearProtection(
            store: store,
            accountKey: WindowStartFixtures.chatgptKey,
            now: now
        )

        let later = now.addingTimeInterval(UsageWindowStartSchedule.cooldown + 60)
        guard case let .reserved(secondID, _, _) = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(at: later),
            attemptID: "attempt-B"
        ) else {
            return XCTFail("second reservation failed")
        }

        // The abandoned attempt answers after the replacement started.
        let late = UsageWindowStartWrites.applySendOutcome(
            .delivered(turnID: "late-A", modelProvider: "openai"),
            attemptID: firstID,
            store: store,
            accountKey: WindowStartFixtures.chatgptKey,
            now: later
        )

        XCTAssertEqual(late, .superseded)
        let persisted = try store.snapshot().record(for: WindowStartFixtures.chatgptKey).state
        XCTAssertEqual(persisted.attemptID, secondID)
        XCTAssertEqual(persisted.phase, .sending, "the newer attempt must stay untouched")
    }

    func testLateConfirmationFromACancelledAttemptIsDropped() throws {
        let store = populatedStore()

        guard case let .reserved(firstID, _, _) = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(),
            attemptID: "attempt-A"
        ) else {
            return XCTFail("first reservation failed")
        }
        UsageWindowStartWrites.applySendOutcome(
            .delivered(turnID: "turn-A", modelProvider: "openai"),
            attemptID: firstID,
            store: store,
            accountKey: WindowStartFixtures.chatgptKey,
            now: now
        )
        UsageWindowStartWrites.clearProtection(
            store: store,
            accountKey: WindowStartFixtures.chatgptKey,
            now: now
        )

        let later = now.addingTimeInterval(UsageWindowStartSchedule.cooldown + 60)
        guard case let .reserved(secondID, _, _) = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(at: later),
            attemptID: "attempt-B"
        ) else {
            return XCTFail("second reservation failed")
        }

        // The abandoned attempt's confirmation read answers after the replacement.
        let late = UsageWindowStartWrites.settleConfirmation(
            attemptID: firstID,
            confirmed: true,
            store: store,
            accountKey: WindowStartFixtures.chatgptKey,
            now: later
        )

        XCTAssertEqual(late, .superseded)
        let persisted = try store.snapshot().record(for: WindowStartFixtures.chatgptKey).state
        XCTAssertEqual(persisted.attemptID, secondID)
        XCTAssertEqual(persisted.phase, .sending)
    }

    func testMatchingAttemptCanStillWrite() throws {
        let store = populatedStore()
        guard case let .reserved(attemptID, _, _) = UsageWindowStartReserver.reserve(
            store: store,
            request: reservationRequest(),
            attemptID: "attempt-A"
        ) else {
            return XCTFail("reservation failed")
        }

        let applied = UsageWindowStartWrites.applySendOutcome(
            .delivered(turnID: "turn-A", modelProvider: "openai"),
            attemptID: attemptID,
            store: store,
            accountKey: WindowStartFixtures.chatgptKey,
            now: now
        )

        guard case let .written(state) = applied else {
            return XCTFail("expected a write, got \(applied)")
        }
        XCTAssertEqual(state.phase, .awaitingConfirmation)
    }

    // MARK: - Helpers

    private func populatedStore() -> UsageWindowStartStore {
        let store = UsageWindowStartStore(directoryURL: directory)
        try? store.transaction { document in
            var record = document.record(for: WindowStartFixtures.chatgptKey)
            record.settings = WindowStartFixtures.settings()
            record.updatedAt = self.now
            document.accounts[WindowStartFixtures.chatgptKey] = record
        }
        return store
    }

    private func reservationRequest(
        at moment: Date? = nil,
        currentGeneration: Int = 1
    ) -> UsageWindowStartReservationRequest {
        let time = moment ?? now
        return UsageWindowStartReservationRequest(
            accountKey: WindowStartFixtures.chatgptKey,
            observation: WindowStartFixtures.idleObservation(at: time),
            previousObservation: WindowStartFixtures.previousIdleObservation(before: time),
            currentAccountGeneration: currentGeneration,
            currentAccountType: WindowStartFixtures.chatgptType,
            models: WindowStartFixtures.models(),
            now: time,
            calendar: WindowStartFixtures.utcCalendar,
            trigger: .automatic,
            isPreviewMode: false
        )
    }
}
