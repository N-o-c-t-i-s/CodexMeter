import XCTest
@testable import CodexMeterCore

final class UsageWindowStartPolicyTests: XCTestCase {
    private let now = WindowStartFixtures.base

    // MARK: - Happy path

    func testProvablyIdleWindowWithValidConfigurationStarts() {
        let evaluation = UsageWindowStartPolicy.evaluate(WindowStartFixtures.input())

        XCTAssertEqual(evaluation.decision, .start)
        XCTAssertEqual(evaluation.activity, .idle)
    }

    func testManualTriggerBypassesTheAutomaticSwitchAndTimeRange() {
        var input = WindowStartFixtures.input(
            settings: WindowStartFixtures.settings(
                autoStartEnabled: false,
                activeHours: UsageWindowActiveHours(
                    isEnabled: true,
                    startMinutes: 9 * 60,
                    endMinutes: 10 * 60
                )
            ),
            trigger: .manual
        )
        input.now = WindowStartFixtures.base

        XCTAssertEqual(UsageWindowStartPolicy.evaluate(input).decision, .start)
    }

    // MARK: - Environment

    func testPreviewModeNeverSends() {
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(isPreviewMode: true)).decision,
            .blocked(.previewModeActive)
        )
    }

    func testAnotherInstanceHoldingTheLockBlocks() {
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(
                WindowStartFixtures.input(isAnotherInstanceActive: true)
            ).decision,
            .blocked(.anotherInstanceActive)
        )
    }

    func testAnOperationInProgressWaits() {
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(
                WindowStartFixtures.input(isOperationInProgress: true)
            ).decision,
            .wait(.operationInProgress)
        )
    }

    // MARK: - Account

    func testMissingAccountTypeMeansNotLoggedIn() {
        var input = WindowStartFixtures.input()
        input.currentAccountType = nil
        XCTAssertEqual(UsageWindowStartPolicy.evaluate(input).decision, .blocked(.notLoggedIn))
    }

    func testAPIKeyAndBedrockAccountsNeverAutoStart() {
        for type in ["apiKey", "amazonBedrock"] {
            var input = WindowStartFixtures.input(
                observation: WindowStartFixtures.idleObservation(accountType: type)
            )
            input.currentAccountType = type
            XCTAssertEqual(
                UsageWindowStartPolicy.evaluate(input).decision,
                .blocked(.unsupportedAccountType),
                "unexpected decision for \(type)"
            )
        }
    }

    func testStaleObservationFromAnotherGenerationBlocks() {
        var input = WindowStartFixtures.input()
        input.currentAccountGeneration = 2
        XCTAssertEqual(UsageWindowStartPolicy.evaluate(input).decision, .blocked(.accountChanged))
    }

    func testChangedAccountKeyBlocks() {
        var input = WindowStartFixtures.input()
        input.currentAccountKey = "chatgpt:someone-else"
        XCTAssertEqual(UsageWindowStartPolicy.evaluate(input).decision, .blocked(.accountChanged))
    }

    // MARK: - Observation quality

    func testSnapshotOlderThanSixtySecondsWaitsForAFreshRead() {
        var observation = WindowStartFixtures.idleObservation(at: now.addingTimeInterval(-61))
        observation = UsageWindowObservation(
            observedAt: now.addingTimeInterval(-61),
            accountGeneration: observation.accountGeneration,
            accountKey: observation.accountKey,
            accountType: observation.accountType,
            authorization: observation.authorization,
            readings: observation.readings
        )
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .wait(.observationStale)
        )
    }

    func testMissingStandardBucketBlocks() {
        let observation = UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(WindowStartFixtures.fiveHourSeconds),
                    observedAt: now,
                    limitID: "base_model_inference"
                )
            ]
        )

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .blocked(.standardBucketMissing)
        )
    }

    func testConflictingFiveHourWindowsBlock() {
        let observation = UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(WindowStartFixtures.fiveHourSeconds),
                    observedAt: now,
                    slot: "primary"
                ),
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(WindowStartFixtures.fiveHourSeconds + 60),
                    observedAt: now,
                    slot: "secondary"
                )
            ]
        )

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .blocked(.conflictingWindowData)
        )
    }

    func testInvalidWindowNumbersAreMetadataFailures() {
        let observation = UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 140,
                    resetsAt: now.addingTimeInterval(60),
                    observedAt: now
                )
            ]
        )

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .blocked(.windowMetadataInvalid)
        )
    }

    // MARK: - Backend permission

    func testOrdinaryUsageDeniedBlocks() {
        let observation = WindowStartFixtures.idleObservation(authorization: .denied)
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .blocked(.ordinaryUsageDenied)
        )
    }

    func testOrdinaryUsageUnknownBlocksInsteadOfInferringRecovery() {
        let observation = WindowStartFixtures.idleObservation(authorization: .unknown)
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .blocked(.ordinaryUsageUnknown)
        )
    }

    func testSpendControlBlockWins() {
        let observation = UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(WindowStartFixtures.fiveHourSeconds),
                    observedAt: now,
                    spendControlReached: true
                )
            ]
        )

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .blocked(.spendControlReached)
        )
    }

    func testRateLimitReachedTypeWins() {
        let observation = UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(WindowStartFixtures.fiveHourSeconds),
                    observedAt: now,
                    rateLimitReachedType: "workspace_member_credits_depleted"
                )
            ]
        )

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .blocked(.rateLimitReached)
        )
    }

    // MARK: - Weekly window

    func testExhaustedWeeklyWindowWaits() {
        let observation = WindowStartFixtures.idleObservation(weeklyUsedPercent: 100)
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .wait(.weeklyLimitExhausted)
        )
    }

    func testExhaustedWeeklyWindowPastItsResetWaitsForTheBackend() {
        let observation = UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(WindowStartFixtures.fiveHourSeconds),
                    observedAt: now,
                    slot: "primary"
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

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(observation: observation)).decision,
            .wait(.weeklyResetPending)
        )
    }

    func testMissingWeeklyWindowDoesNotBlockATrustedRead() {
        let observation = WindowStartFixtures.idleObservation(weeklyUsedPercent: nil)
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(
                observation: observation,
                previousObservation: WindowStartFixtures.previousIdleObservation()
            )).decision,
            .start
        )
    }

    // MARK: - Window state

    func testRunningWindowIsReportedWithoutSending() {
        let evaluation = UsageWindowStartPolicy.evaluate(
            WindowStartFixtures.input(observation: WindowStartFixtures.activeObservation())
        )
        XCTAssertEqual(evaluation.decision, .wait(.windowActive))
        XCTAssertEqual(evaluation.activity, .active)
    }

    func testHypotheticalCandidateWaitsForASecondReading() {
        let evaluation = UsageWindowStartPolicy.evaluate(
            WindowStartFixtures.input(observation: WindowStartFixtures.candidateObservation())
        )
        XCTAssertEqual(evaluation.decision, .wait(.awaitingIdleConfirmation))
        XCTAssertEqual(evaluation.activity, .unknown)
    }

    func testUnknownWindowStateBlocks() {
        let observation = WindowStartFixtures.candidateObservation()
        var input = WindowStartFixtures.input(observation: observation)
        // Force the classifier out of the candidate branch by expiring the reset.
        input.observation = UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: WindowStartFixtures.chatgptKey,
            accountType: "chatgpt",
            authorization: .allowed,
            readings: [
                WindowStartFixtures.reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(-30),
                    observedAt: now
                )
            ]
        )

        XCTAssertEqual(UsageWindowStartPolicy.evaluate(input).decision, .blocked(.windowStateUnknown))
    }

    // MARK: - Configuration

    func testAutomaticTriggerRequiresTheSwitch() {
        let evaluation = UsageWindowStartPolicy.evaluate(
            WindowStartFixtures.input(
                settings: WindowStartFixtures.settings(autoStartEnabled: false)
            )
        )
        XCTAssertEqual(evaluation.decision, .blocked(.autoStartDisabled))
        // A running window is still reported even while automatic sending is off.
        XCTAssertEqual(evaluation.activity, .idle)
    }

    func testOutsideActiveHoursWaits() {
        let calendar = WindowStartFixtures.calendar(timeZoneIdentifier: "UTC")
        let hour = calendar.component(.hour, from: now)
        let start = ((hour + 2) % 24) * 60
        let end = ((hour + 3) % 24) * 60

        let evaluation = UsageWindowStartPolicy.evaluate(
            WindowStartFixtures.input(
                settings: WindowStartFixtures.settings(
                    activeHours: UsageWindowActiveHours(
                        isEnabled: true,
                        startMinutes: start,
                        endMinutes: end
                    )
                ),
                calendar: calendar
            )
        )
        XCTAssertEqual(evaluation.decision, .wait(.outsideActiveHours))
    }

    func testCrossMidnightActiveHoursAreHonored() {
        let calendar = WindowStartFixtures.calendar(timeZoneIdentifier: "UTC")
        let hour = calendar.component(.hour, from: now)
        // A range that wraps midnight and excludes the current hour.
        let start = ((hour + 1) % 24) * 60
        let end = ((hour + 12) % 24) * 60
        let hours = UsageWindowActiveHours(isEnabled: true, startMinutes: start, endMinutes: end)

        XCTAssertFalse(hours.contains(now, calendar: calendar))
    }

    func testMissingModelSelectionBlocks() {
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(
                WindowStartFixtures.input(settings: WindowStartFixtures.settings(modelID: nil))
            ).decision,
            .blocked(.modelNotSelected)
        )
    }

    func testUnavailableCatalogBlocks() {
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(models: [])).decision,
            .blocked(.modelUnavailable)
        )
    }

    func testRemovedModelBlocksWithoutSilentSubstitution() {
        let input = WindowStartFixtures.input(
            models: WindowStartFixtures.models(id: "gpt-5-mini")
        )
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(input).decision,
            .blocked(.modelUnavailable)
        )
    }

    func testUnsupportedEffortBlocks() {
        let input = WindowStartFixtures.input(
            settings: WindowStartFixtures.settings(reasoningEffort: "ultra"),
            models: WindowStartFixtures.models(efforts: ["low", "medium"])
        )
        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(input).decision,
            .blocked(.reasoningEffortUnavailable)
        )
    }

    // MARK: - Duplicate protection

    func testCooldownWaits() {
        var state = UsageWindowStartState.empty
        state.phase = .confirmed
        state.lastSentAt = now.addingTimeInterval(-10 * 60)
        state.episodeOpen = false

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(state: state)).decision,
            .wait(.coolingDown)
        )
    }

    func testCooldownEndingIsNotEnoughWhileTheEpisodeStaysOpen() {
        var state = UsageWindowStartState.empty
        state.phase = .confirmed
        state.lastSentAt = now.addingTimeInterval(-3 * 3_600)
        state.episodeOpen = true
        state.lastOutcomeCode = .confirmed

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(state: state)).decision,
            .wait(.sameEpisodeAlreadySent)
        )
    }

    func testAwaitingConfirmationDoesNotResend() {
        var state = UsageWindowStartState.empty
        state.phase = .awaitingConfirmation
        state.episodeOpen = true
        state.lastSentAt = now.addingTimeInterval(-30)

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(state: state)).decision,
            .wait(.confirmationPending)
        )
    }

    func testUnknownDeliveryKeepsProtectionUntilTheUserResolvesIt() {
        var state = UsageWindowStartState.empty
        state.phase = .failed
        state.episodeOpen = true
        state.lastOutcomeCode = .deliveryUnknown
        state.lastFailureCode = .timeout
        state.lastSentAt = now.addingTimeInterval(-3 * 3_600)

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(state: state)).decision,
            .blocked(.previousDeliveryUnknown)
        )
    }

    func testResolvedEpisodeSendsAgainAfterTheCooldown() {
        var state = UsageWindowStartState.empty
        state.phase = .confirmed
        state.episodeOpen = false
        state.lastOutcomeCode = .confirmed
        state.lastSentAt = now.addingTimeInterval(-31 * 60)
        state.lastConfirmedAt = now.addingTimeInterval(-20 * 60)

        XCTAssertEqual(
            UsageWindowStartPolicy.evaluate(WindowStartFixtures.input(state: state)).decision,
            .start
        )
    }

    // MARK: - Read-only activity

    func testActivityIsReportedEvenWhenNothingCanBeSent() {
        let observation = WindowStartFixtures.activeObservation()
        XCTAssertEqual(
            UsageWindowStartPolicy.activity(
                observation: observation,
                previousObservation: nil,
                now: now
            ),
            .active
        )
    }
}
