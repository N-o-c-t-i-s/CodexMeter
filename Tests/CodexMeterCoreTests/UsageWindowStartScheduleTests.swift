import XCTest
@testable import CodexMeterCore

final class UsageWindowStartScheduleTests: XCTestCase {
    private let now = WindowStartFixtures.base
    private let calendar = WindowStartFixtures.calendar(timeZoneIdentifier: "UTC")

    // MARK: - Active hours

    func testAllDayRangeAlwaysContainsAndHasNoBoundary() {
        XCTAssertTrue(UsageWindowActiveHours.always.contains(now, calendar: calendar))
        XCTAssertTrue(UsageWindowActiveHours.always.isAllDay)
        XCTAssertNil(UsageWindowActiveHours.always.nextBoundary(after: now, calendar: calendar))
    }

    func testEqualStartAndEndMeansAllDay() {
        let hours = UsageWindowActiveHours(isEnabled: true, startMinutes: 600, endMinutes: 600)
        XCTAssertTrue(hours.isAllDay)
        XCTAssertTrue(hours.contains(now, calendar: calendar))
    }

    func testSimpleRangeExcludesTheEndBoundary() {
        let hours = UsageWindowActiveHours(
            isEnabled: true,
            startMinutes: 9 * 60,
            endMinutes: 17 * 60
        )
        XCTAssertTrue(hours.contains(date(hour: 9, minute: 0), calendar: calendar))
        XCTAssertTrue(hours.contains(date(hour: 16, minute: 59), calendar: calendar))
        XCTAssertFalse(hours.contains(date(hour: 17, minute: 0), calendar: calendar))
        XCTAssertFalse(hours.contains(date(hour: 8, minute: 59), calendar: calendar))
    }

    func testCrossMidnightRangeWraps() {
        let hours = UsageWindowActiveHours(
            isEnabled: true,
            startMinutes: 22 * 60,
            endMinutes: 6 * 60
        )
        XCTAssertTrue(hours.contains(date(hour: 23, minute: 30), calendar: calendar))
        XCTAssertTrue(hours.contains(date(hour: 3, minute: 0), calendar: calendar))
        XCTAssertFalse(hours.contains(date(hour: 12, minute: 0), calendar: calendar))
        XCTAssertFalse(hours.contains(date(hour: 6, minute: 0), calendar: calendar))
    }

    func testNextBoundaryMovesToTheRangeStart() {
        let hours = UsageWindowActiveHours(
            isEnabled: true,
            startMinutes: 9 * 60,
            endMinutes: 17 * 60
        )
        let current = date(hour: 3, minute: 0)
        let boundary = hours.nextBoundary(after: current, calendar: calendar)

        XCTAssertEqual(boundary.map { hour(of: $0) }, 9)
    }

    func testNextBoundaryMovesToTomorrowWhenTheRangeAlreadyEnded() {
        let hours = UsageWindowActiveHours(
            isEnabled: true,
            startMinutes: 9 * 60,
            endMinutes: 17 * 60
        )
        let current = date(hour: 20, minute: 0)
        guard let boundary = hours.nextBoundary(after: current, calendar: calendar) else {
            return XCTFail("expected a boundary")
        }

        XCTAssertGreaterThan(boundary, current)
        XCTAssertTrue(hours.contains(boundary, calendar: calendar))
        XCTAssertEqual(hour(of: boundary), 9)
    }

    func testDaylightSavingMidnightToMidnightRangesStayWallClockExact() {
        let newYork = WindowStartFixtures.calendar(timeZoneIdentifier: "America/New_York")
        let hours = UsageWindowActiveHours(
            isEnabled: true,
            startMinutes: 9 * 60,
            endMinutes: 17 * 60
        )

        // 2026-03-08 is the US spring-forward day: 02:00 does not exist locally.
        for (hour, minute) in [(9, 0), (10, 30), (16, 59)] {
            let probe = newYork.date(
                from: DateComponents(year: 2026, month: 3, day: 8, hour: hour, minute: minute)
            )!
            XCTAssertTrue(hours.contains(probe, calendar: newYork), "\(hour):\(minute) should be inside")
        }
        let justAfter = newYork.date(
            from: DateComponents(year: 2026, month: 3, day: 8, hour: 17, minute: 0)
        )!
        XCTAssertFalse(hours.contains(justAfter, calendar: newYork))

        // The next opening is still 09:00 on the wall clock.
        let earlyMorning = newYork.date(
            from: DateComponents(year: 2026, month: 3, day: 8, hour: 5, minute: 0)
        )!
        guard let boundary = hours.nextBoundary(after: earlyMorning, calendar: newYork) else {
            return XCTFail("expected a boundary across the DST transition")
        }
        XCTAssertEqual(newYork.component(.hour, from: boundary), 9)
        XCTAssertEqual(newYork.component(.day, from: boundary), 8)
    }

    func testFallBackDayStillUsesLocalWallClockMinutes() {
        let newYork = WindowStartFixtures.calendar(timeZoneIdentifier: "America/New_York")
        let hours = UsageWindowActiveHours(
            isEnabled: true,
            startMinutes: 22 * 60,
            endMinutes: 6 * 60
        )

        // 2026-11-01 is the US fall-back day; 01:30 happens twice locally.
        let inside = newYork.date(
            from: DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 30)
        )!
        let outside = newYork.date(
            from: DateComponents(year: 2026, month: 11, day: 1, hour: 12, minute: 0)
        )!

        XCTAssertTrue(hours.contains(inside, calendar: newYork))
        XCTAssertFalse(hours.contains(outside, calendar: newYork))
    }

    // MARK: - Deadlines

    func testRunningWindowSchedulesAResetCheckWithGrace() {
        let observation = WindowStartFixtures.activeObservation()
        let deadline = UsageWindowStartSchedule.nextDeadline(
            observation: observation,
            settings: WindowStartFixtures.settings(),
            state: .empty,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(deadline?.reason, .windowReset)
        let expected = now
            .addingTimeInterval(2 * 3_600)
            .addingTimeInterval(UsageWindowStartSchedule.resetGrace)
        XCTAssertEqual(deadline?.date, expected)
    }

    func testExhaustedWeeklyWindowSchedulesItsReset() {
        let observation = WindowStartFixtures.idleObservation(weeklyUsedPercent: 100)
        let deadlines = UsageWindowStartSchedule.deadlines(
            observation: observation,
            settings: WindowStartFixtures.settings(),
            state: .empty,
            now: now,
            calendar: calendar
        )

        XCTAssertTrue(deadlines.contains { $0.reason == .weeklyReset })
    }

    func testConfirmationDeadlineIsScheduled() {
        var state = UsageWindowStartState.empty
        state.phase = .awaitingConfirmation
        state.episodeOpen = true
        state.lastSentAt = now
        state.confirmationDeadline = now.addingTimeInterval(
            UsageWindowStartSchedule.confirmationDelay
        )

        let deadline = UsageWindowStartSchedule.nextDeadline(
            observation: WindowStartFixtures.idleObservation(),
            settings: WindowStartFixtures.settings(),
            state: state,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(deadline?.reason, .confirmation)
    }

    func testCooldownEndIsScheduledOnlyWhenNothingElseIsSooner() {
        var state = UsageWindowStartState.empty
        state.lastSentAt = now.addingTimeInterval(-60)
        state.phase = .confirmed

        let deadlines = UsageWindowStartSchedule.deadlines(
            observation: nil,
            settings: WindowStartFixtures.settings(),
            state: state,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(deadlines.map(\.reason), [.cooldownEnd])
        XCTAssertEqual(
            deadlines.first?.date,
            now.addingTimeInterval(UsageWindowStartSchedule.cooldown - 60)
        )
    }

    func testActiveHoursStartIsScheduledOnlyWhenAutomaticSendingIsOn() {
        let hours = UsageWindowActiveHours(
            isEnabled: true,
            startMinutes: 9 * 60,
            endMinutes: 17 * 60
        )
        let off = UsageWindowStartSchedule.deadlines(
            observation: nil,
            settings: WindowStartFixtures.settings(autoStartEnabled: false, activeHours: hours),
            state: .empty,
            now: date(hour: 3, minute: 0),
            calendar: calendar
        )
        let on = UsageWindowStartSchedule.deadlines(
            observation: nil,
            settings: WindowStartFixtures.settings(autoStartEnabled: true, activeHours: hours),
            state: .empty,
            now: date(hour: 3, minute: 0),
            calendar: calendar
        )

        XCTAssertFalse(off.contains { $0.reason == .activeHoursStart })
        XCTAssertTrue(on.contains { $0.reason == .activeHoursStart })
    }

    func testExpiredResetSchedulesAnImmediateReread() {
        let observation = UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(-60),
                    observedAt: now
                )
            ]
        )

        let deadline = UsageWindowStartSchedule.nextDeadline(
            observation: observation,
            settings: WindowStartFixtures.settings(),
            state: .empty,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(deadline?.reason, .windowReset)
        XCTAssertEqual(
            deadline?.date,
            now.addingTimeInterval(UsageWindowStartSchedule.staleRetryDelay)
        )
        // A recheck that has not produced a new reset is bounded, not periodic.
        XCTAssertEqual(deadline?.isRetry, true)
    }

    func testScheduledResetsAreNotMarkedAsRetries() {
        let deadline = UsageWindowStartSchedule.nextDeadline(
            observation: WindowStartFixtures.activeObservation(),
            settings: WindowStartFixtures.settings(),
            state: .empty,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(deadline?.isRetry, false)
    }

    func testWeeklyResetThatAlreadyPassedIsABoundedRetry() {
        let observation = WindowStartObservationFixture.weeklyPastReset(at: now)
        let deadlines = UsageWindowStartSchedule.deadlines(
            observation: observation,
            settings: WindowStartFixtures.settings(),
            state: .empty,
            now: now,
            calendar: calendar
        )

        let weekly = deadlines.first { $0.reason == .weeklyReset }
        XCTAssertEqual(weekly?.isRetry, true)
        XCTAssertEqual(
            weekly?.date,
            now.addingTimeInterval(UsageWindowStartSchedule.staleRetryDelay)
        )
    }

    func testDeadlinesAreSortedByDate() {
        var state = UsageWindowStartState.empty
        state.lastSentAt = now.addingTimeInterval(-60)
        state.confirmationDeadline = now.addingTimeInterval(90)

        let deadlines = UsageWindowStartSchedule.deadlines(
            observation: WindowStartFixtures.activeObservation(),
            settings: WindowStartFixtures.settings(),
            state: state,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(deadlines.map(\.date), deadlines.map(\.date).sorted())
    }

    // MARK: - Helpers

    private func date(hour: Int, minute: Int) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components) ?? now
    }

    private func hour(of date: Date) -> Int {
        calendar.component(.hour, from: date)
    }
}

private enum WindowStartObservationFixture {
    static func weeklyPastReset(at now: Date) -> UsageWindowObservation {
        UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(WindowStartFixtures.fiveHourSeconds),
                    observedAt: now
                ),
                WindowStartFixtures.reading(
                    usedPercent: 100,
                    resetsAt: now.addingTimeInterval(-60),
                    observedAt: now,
                    durationMins: 10_080,
                    slot: "secondary"
                )
            ]
        )
    }
}
