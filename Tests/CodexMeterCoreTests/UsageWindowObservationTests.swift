import XCTest
@testable import CodexMeterCore

final class UsageWindowObservationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let fiveHours: TimeInterval = 300 * 60
    private let week: TimeInterval = 10_080 * 60

    // MARK: - Parsing

    func testLegacySingleSnapshotIsParsed() {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1_800_003_600],
                "secondary": ["usedPercent": 7, "windowDurationMins": 10_080, "resetsAt": 1_800_600_000]
            ]
        ]

        let readings = UsageWindowObservationParser.readings(
            fromRateLimitsResult: result,
            observedAt: base
        )

        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(readings.map(\.limitID), ["codex", "codex"])
        XCTAssertEqual(readings.map(\.durationMins), [300, 10_080])
        XCTAssertEqual(readings.map(\.usedPercent), [42, 7])
    }

    func testMultiBucketResponseKeepsOnlyTheStandardBucketForTheStarter() {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "primary": ["usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1_800_003_600],
                    "secondary": ["usedPercent": 20, "windowDurationMins": 10_080, "resetsAt": 1_800_600_000]
                ],
                "base_model_inference": [
                    "limitId": "base_model_inference",
                    "secondary": ["usedPercent": 88, "windowDurationMins": 10_080, "resetsAt": 1_800_600_000]
                ]
            ]
        ]

        let observation = makeObservation(from: result)

        XCTAssertEqual(observation.readings.count, 3)
        XCTAssertEqual(observation.standardBucketReadings.count, 2)
        XCTAssertEqual(observation.shortWindow?.usedPercent, 10)
        XCTAssertEqual(observation.weeklyWindow?.usedPercent, 20)
    }

    func testReserveBucketAloneDoesNotSatisfyTheStandardWindow() {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "base_model_inference": [
                    "limitId": "base_model_inference",
                    "primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1_800_018_000]
                ]
            ]
        ]

        let observation = makeObservation(from: result)

        XCTAssertNil(observation.shortWindow)
        XCTAssertNil(observation.weeklyWindow)
    }

    func testPrimaryAndSecondarySlotsMaySwapWithoutChangingTheTarget() {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "primary": ["usedPercent": 15, "windowDurationMins": 10_080, "resetsAt": 1_800_600_000],
                    "secondary": ["usedPercent": 55, "windowDurationMins": 300, "resetsAt": 1_800_003_600]
                ]
            ]
        ]

        let observation = makeObservation(from: result)

        XCTAssertEqual(observation.shortWindow?.usedPercent, 55)
        XCTAssertEqual(observation.weeklyWindow?.usedPercent, 15)
        XCTAssertEqual(observation.shortWindow?.windowIdentity, "codex:300")
        XCTAssertEqual(observation.weeklyWindow?.windowIdentity, "codex:10080")
    }

    func testDuplicateFiveHourWindowsAreConflictsRatherThanAPick() {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1_800_018_000],
                    "secondary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1_800_019_000]
                ]
            ]
        ]

        let observation = makeObservation(from: result)

        XCTAssertTrue(observation.hasConflictingWindows)
        XCTAssertNil(observation.shortWindow)
    }

    func testNonStandardDurationsAreRetainedButNotTargeted() {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 3, "windowDurationMins": 1_440, "resetsAt": 1_800_090_000]
            ]
        ]

        let observation = makeObservation(from: result)

        XCTAssertEqual(observation.readings.count, 1)
        XCTAssertNil(observation.shortWindow)
        XCTAssertNil(observation.weeklyWindow)
    }

    func testOrdinaryUsageAuthorizationKeepsUnknownDistinctFromDenied() {
        XCTAssertEqual(
            makeObservation(from: ["rateLimits": [:], "ordinaryUsageAllowed": true]).authorization,
            .allowed
        )
        XCTAssertEqual(
            makeObservation(from: ["rateLimits": [:], "ordinaryUsageAllowed": false]).authorization,
            .denied
        )
        XCTAssertEqual(
            makeObservation(from: ["rateLimits": [:], "ordinaryUsageAllowed": NSNull()]).authorization,
            .unknown
        )
        XCTAssertEqual(makeObservation(from: ["rateLimits": [:]]).authorization, .unknown)
    }

    func testBackendBlockFieldsAreParsedSeparately() {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "spendControlReached": true,
                    "rateLimitReachedType": "workspace_owner_credits_depleted",
                    "primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": 1_800_018_000]
                ]
            ]
        ]

        let reading = makeObservation(from: result).shortWindow

        XCTAssertEqual(reading?.spendControlReached, true)
        XCTAssertEqual(reading?.rateLimitReachedType, "workspace_owner_credits_depleted")
    }

    func testZeroResetTimestampIsNotTreatedAsADate() {
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": ["usedPercent": 0, "windowDurationMins": 300, "resetsAt": 0]
            ]
        ]

        XCTAssertNil(makeObservation(from: result).shortWindow?.resetsAt)
    }

    // MARK: - Activity classification

    func testNonZeroUsageIsAlwaysActive() {
        let assessment = UsageWindowActivityClassifier.assess(
            current: reading(usedPercent: 40, resetAt: base.addingTimeInterval(3_600)),
            previous: nil,
            at: base
        )
        XCTAssertEqual(assessment.activity, .active)
    }

    func testHypotheticalShapeAloneIsOnlyACandidate() {
        let assessment = UsageWindowActivityClassifier.assess(
            current: reading(usedPercent: 0, resetAt: base.addingTimeInterval(fiveHours)),
            previous: nil,
            at: base
        )
        XCTAssertEqual(assessment.activity, .unknown)
        XCTAssertTrue(assessment.isHypotheticalCandidate)
    }

    func testFixedResetBehindTheThresholdProvesActiveEvenAtZeroPercent() {
        let started = base.addingTimeInterval(-60)
        let assessment = UsageWindowActivityClassifier.assess(
            current: reading(usedPercent: 0, resetAt: started.addingTimeInterval(fiveHours)),
            previous: nil,
            at: base
        )
        XCTAssertEqual(assessment.activity, .active)
    }

    func testToleranceBoundaryStaysOfficialCandidate() {
        let tolerance = UsageWindowActivityClassifier.hypotheticalTolerance
        let atFloor = reading(
            usedPercent: 0,
            resetAt: base.addingTimeInterval(fiveHours - tolerance)
        )
        let justBehind = reading(
            usedPercent: 0,
            resetAt: base.addingTimeInterval(fiveHours - tolerance - 1)
        )

        XCTAssertEqual(
            UsageWindowActivityClassifier.assess(current: atFloor, previous: nil, at: base).activity,
            .unknown
        )
        XCTAssertEqual(
            UsageWindowActivityClassifier.assess(current: justBehind, previous: nil, at: base).activity,
            .active
        )
    }

    func testSlidingResetAcrossSixtySecondsProvesIdle() {
        let previousAt = base.addingTimeInterval(-60)
        let previous = reading(
            usedPercent: 0,
            resetAt: previousAt.addingTimeInterval(fiveHours),
            observedAt: previousAt
        )
        let current = reading(usedPercent: 0, resetAt: base.addingTimeInterval(fiveHours))

        let assessment = UsageWindowActivityClassifier.assess(
            current: current,
            previous: previous,
            at: base
        )

        XCTAssertEqual(assessment.activity, .idle)
        XCTAssertTrue(assessment.isHypotheticalCandidate)
    }

    func testFixedResetAcrossSixtySecondsIsNotIdle() {
        let previousAt = base.addingTimeInterval(-60)
        let fixedReset = previousAt.addingTimeInterval(fiveHours)
        let previous = reading(usedPercent: 0, resetAt: fixedReset, observedAt: previousAt)
        let current = reading(usedPercent: 0, resetAt: fixedReset)

        let assessment = UsageWindowActivityClassifier.assess(
            current: current,
            previous: previous,
            at: base
        )

        XCTAssertNotEqual(assessment.activity, .idle)
    }

    func testReadingsCloserThanTheSlidingIntervalDoNotProveIdle() {
        let previousAt = base.addingTimeInterval(-5)
        let previous = reading(
            usedPercent: 0,
            resetAt: previousAt.addingTimeInterval(fiveHours),
            observedAt: previousAt
        )
        let current = reading(usedPercent: 0, resetAt: base.addingTimeInterval(fiveHours))

        let assessment = UsageWindowActivityClassifier.assess(
            current: current,
            previous: previous,
            at: base
        )

        XCTAssertEqual(assessment.activity, .unknown)
        XCTAssertTrue(assessment.isHypotheticalCandidate)
    }

    func testPreviousReadingWithUsageDoesNotSupportIdle() {
        let previousAt = base.addingTimeInterval(-60)
        let previous = reading(
            usedPercent: 4,
            resetAt: previousAt.addingTimeInterval(fiveHours),
            observedAt: previousAt
        )
        let current = reading(usedPercent: 0, resetAt: base.addingTimeInterval(fiveHours))

        XCTAssertEqual(
            UsageWindowActivityClassifier.assess(
                current: current,
                previous: previous,
                at: base
            ).activity,
            .unknown
        )
    }

    func testExpiredResetIsUnknownRatherThanIdle() {
        let assessment = UsageWindowActivityClassifier.assess(
            current: reading(usedPercent: 0, resetAt: base.addingTimeInterval(-120)),
            previous: nil,
            at: base
        )
        XCTAssertEqual(assessment.activity, .unknown)
        XCTAssertFalse(assessment.isHypotheticalCandidate)
    }

    func testResetBeyondOneWindowLengthIsAnomalous() {
        let assessment = UsageWindowActivityClassifier.assess(
            current: reading(usedPercent: 0, resetAt: base.addingTimeInterval(fiveHours + 600)),
            previous: nil,
            at: base
        )
        XCTAssertEqual(assessment.activity, .unknown)
    }

    func testMissingMetadataIsUnknown() {
        XCTAssertEqual(
            UsageWindowActivityClassifier.assess(
                current: reading(usedPercent: 0, resetAt: nil),
                previous: nil,
                at: base
            ).activity,
            .unknown
        )
        XCTAssertEqual(
            UsageWindowActivityClassifier.assess(
                current: reading(usedPercent: 0, resetAt: base.addingTimeInterval(fiveHours), durationMins: nil),
                previous: nil,
                at: base
            ).activity,
            .unknown
        )
        XCTAssertEqual(
            UsageWindowActivityClassifier.assess(
                current: reading(usedPercent: 250, resetAt: base.addingTimeInterval(60)),
                previous: nil,
                at: base
            ).activity,
            .unknown
        )
    }

    // MARK: - Helpers

    private func makeObservation(from result: [String: Any]) -> UsageWindowObservation {
        UsageWindowObservation(
            observedAt: base,
            accountGeneration: 1,
            accountKey: "chatgpt:test",
            accountType: "chatgpt",
            authorization: UsageWindowObservationParser.authorization(fromRateLimitsResult: result),
            readings: UsageWindowObservationParser.readings(
                fromRateLimitsResult: result,
                observedAt: base
            )
        )
    }

    private func reading(
        usedPercent: Int,
        resetAt: Date?,
        durationMins: Int? = 300,
        observedAt: Date? = nil
    ) -> UsageWindowReading {
        UsageWindowReading(
            observedAt: observedAt ?? base,
            limitID: "codex",
            limitName: "Codex",
            slot: "primary",
            usedPercent: usedPercent,
            windowDurationMins: durationMins,
            resetsAt: resetAt,
            rateLimitReachedType: nil,
            spendControlReached: nil
        )
    }
}
