import XCTest
@testable import CodexMeterCore

final class UsageWindowObservationHistoryTests: XCTestCase {
    private let base = WindowStartFixtures.base

    func testForegroundTenSecondCadenceEventuallyProvesIdle() {
        var history = UsageWindowObservationHistory()
        for offset in stride(from: 0, through: 60, by: 10) {
            let current = WindowStartFixtures.idleObservation(at: base.addingTimeInterval(Double(offset)))
            let previous = history.append(current)
            let activity = UsageWindowStartPolicy.activity(
                observation: current, previousObservation: previous, now: current.observedAt
            )
            XCTAssertEqual(activity, offset < 20 ? .unknown : .idle)
        }
    }

    func testBackgroundCadenceKeepsNormalIdleProof() {
        var history = UsageWindowObservationHistory()
        let first = WindowStartFixtures.idleObservation(at: base)
        XCTAssertNil(history.append(first))
        XCTAssertEqual(history.append(WindowStartFixtures.idleObservation(at: base.addingTimeInterval(60))), first)
    }

    func testAccountAndGenerationChangesDiscardComparison() {
        var history = UsageWindowObservationHistory()
        _ = history.append(WindowStartFixtures.idleObservation(at: base))
        XCTAssertNil(history.append(WindowStartFixtures.idleObservation(
            at: base.addingTimeInterval(30), accountKey: "other-account"
        )))
        XCTAssertNil(history.append(WindowStartFixtures.idleObservation(
            at: base.addingTimeInterval(60), accountKey: "other-account", generation: 2
        )))
    }

    func testInterveningActiveReadingBreaksOldIdleProof() {
        var history = UsageWindowObservationHistory()
        _ = history.append(WindowStartFixtures.idleObservation(at: base))
        _ = history.append(WindowStartFixtures.activeObservation(at: base.addingTimeInterval(10)))
        let current = WindowStartFixtures.idleObservation(at: base.addingTimeInterval(20))
        XCTAssertNil(history.append(current))
        let next = WindowStartFixtures.idleObservation(at: base.addingTimeInterval(30))
        XCTAssertEqual(UsageWindowStartPolicy.activity(
            observation: next, previousObservation: history.append(next), now: next.observedAt
        ), .unknown)
    }

    func testClockRollbackAndLongOutageDiscardComparison() {
        var history = UsageWindowObservationHistory()
        _ = history.append(WindowStartFixtures.idleObservation(at: base))
        XCTAssertNil(history.append(WindowStartFixtures.idleObservation(at: base.addingTimeInterval(-10))))
        XCTAssertNil(history.append(WindowStartFixtures.idleObservation(at: base.addingTimeInterval(180))))
    }

    func testFixedNewWindowNeverBecomesIdleUnderForegroundPolling() {
        var history = UsageWindowObservationHistory()
        for offset in stride(from: 0, through: 60, by: 10) {
            let now = base.addingTimeInterval(Double(offset))
            let current = UsageWindowObservation(
                observedAt: now, accountGeneration: 1, accountKey: WindowStartFixtures.chatgptKey,
                accountType: "chatgpt", authorization: .allowed,
                readings: [WindowStartFixtures.reading(
                    usedPercent: 0, resetsAt: base.addingTimeInterval(18_000), observedAt: now
                )]
            )
            XCTAssertNotEqual(UsageWindowStartPolicy.activity(
                observation: current, previousObservation: history.append(current), now: now
            ), .idle)
        }
    }
}
