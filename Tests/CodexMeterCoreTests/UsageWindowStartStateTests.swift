import XCTest
@testable import CodexMeterCore

final class UsageWindowStartStateTests: XCTestCase {
    private let now = WindowStartFixtures.base

    func testEmptyStateDoesNotBlockAndCarriesNoResult() {
        let state = UsageWindowStartState.empty

        XCTAssertFalse(state.blocksNewAttempt)
        XCTAssertNil(state.lastOutcomeCode)
        XCTAssertNil(state.lastSentAt)
        XCTAssertEqual(state.phase, .idle)
    }

    func testOpenEpisodeBlocksEvenWithoutAPhaseFlag() {
        var state = UsageWindowStartState.empty
        state.episodeOpen = true
        XCTAssertTrue(state.blocksNewAttempt)
    }

    func testSendingAndAwaitingConfirmationBlock() {
        var state = UsageWindowStartState.empty
        state.phase = .sending
        XCTAssertTrue(state.blocksNewAttempt)
        state.phase = .awaitingConfirmation
        XCTAssertTrue(state.blocksNewAttempt)
        state.phase = .confirmed
        XCTAssertFalse(state.blocksNewAttempt)
    }

    func testPersistedDocumentRoundTripsThroughJSON() throws {
        var record = UsageWindowStartAccountRecord.empty(at: now)
        record.settings = WindowStartFixtures.settings()
        record.state.phase = .awaitingConfirmation
        record.state.episodeOpen = true
        record.state.attemptID = "attempt-1"
        record.state.reservedAt = now
        record.state.lastSentAt = now
        record.state.targetWindowIdentity = "codex:300"
        record.state.confirmationDeadline = now.addingTimeInterval(90)

        let document = UsageWindowStartPersistedState(
            schemaVersion: UsageWindowStartPersistedState.currentSchemaVersion,
            accounts: [WindowStartFixtures.chatgptKey: record]
        )

        let data = try UsageWindowStartStore.encode(document)
        let decoded = try UsageWindowStartStore.decode(data)

        XCTAssertEqual(decoded, document)
    }

    func testDocumentWithoutAnyAccountsIsEmpty() {
        XCTAssertTrue(UsageWindowStartPersistedState.empty.accounts.isEmpty)
        XCTAssertEqual(
            UsageWindowStartPersistedState.empty.record(for: "chatgpt:x").settings,
            .defaultValue
        )
    }

    func testCorruptDocumentIsRejected() {
        XCTAssertThrowsError(
            try UsageWindowStartStore.decode(Data("{ not json".utf8))
        ) { error in
            XCTAssertEqual(error as? UsageWindowStartStoreError, .corrupt)
        }
    }

    func testFutureSchemaIsRejectedRatherThanDowngraded() throws {
        let document = UsageWindowStartPersistedState(
            schemaVersion: UsageWindowStartPersistedState.currentSchemaVersion + 1,
            accounts: [:]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(document)

        XCTAssertThrowsError(try UsageWindowStartStore.decode(data)) { error in
            XCTAssertEqual(
                error as? UsageWindowStartStoreError,
                .unsupportedSchema(UsageWindowStartPersistedState.currentSchemaVersion + 1)
            )
        }
    }

    func testAccountCapKeepsTheMostRecentlyTouchedRecords() {
        var document = UsageWindowStartPersistedState.empty
        for index in 0..<(UsageWindowStartPersistedState.maximumAccounts + 3) {
            var record = UsageWindowStartAccountRecord.empty(at: now)
            record.updatedAt = now.addingTimeInterval(TimeInterval(index))
            document.accounts["chatgpt:\(index)"] = record
        }

        document.pruneAccounts()

        XCTAssertEqual(document.accounts.count, UsageWindowStartPersistedState.maximumAccounts)
        XCTAssertNil(document.accounts["chatgpt:0"])
        XCTAssertNotNil(document.accounts["chatgpt:\(UsageWindowStartPersistedState.maximumAccounts + 2)"])
    }
}
