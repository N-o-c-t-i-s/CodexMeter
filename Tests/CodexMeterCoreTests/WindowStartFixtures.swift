import Foundation
@testable import CodexMeterCore

/// Shared builders so policy, state, store, and runner tests describe the same
/// scenarios with the same vocabulary.
enum WindowStartFixtures {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    static let fiveHourSeconds: TimeInterval = 300 * 60
    static let weeklySeconds: TimeInterval = 10_080 * 60

    static let chatgptKey = "chatgpt:fixture"
    static let chatgptType = "chatgpt"

    static func reading(
        usedPercent: Int,
        resetsAt: Date?,
        observedAt: Date,
        durationMins: Int? = 300,
        limitID: String = "codex",
        slot: String = "primary",
        spendControlReached: Bool? = nil,
        rateLimitReachedType: String? = nil
    ) -> UsageWindowReading {
        UsageWindowReading(
            observedAt: observedAt,
            limitID: limitID,
            limitName: "Codex",
            slot: slot,
            usedPercent: usedPercent,
            windowDurationMins: durationMins,
            resetsAt: resetsAt,
            rateLimitReachedType: rateLimitReachedType,
            spendControlReached: spendControlReached
        )
    }

    /// The current half of a provably idle pair: 0% with a reset one full
    /// window ahead. On its own this is only a hypothetical candidate.
    static func idleObservation(
        at now: Date = base,
        accountKey: String = chatgptKey,
        accountType: String = chatgptType,
        generation: Int = 1,
        authorization: UsageWindowAuthorization = .allowed,
        weeklyUsedPercent: Int? = 20,
        extraReadings: [UsageWindowReading] = []
    ) -> UsageWindowObservation {
        var readings: [UsageWindowReading] = [
            reading(
                usedPercent: 0,
                resetsAt: now.addingTimeInterval(fiveHourSeconds),
                observedAt: now
            )
        ]
        if let weeklyUsedPercent {
            readings.append(reading(
                usedPercent: weeklyUsedPercent,
                resetsAt: now.addingTimeInterval(weeklySeconds),
                observedAt: now,
                durationMins: 10_080,
                slot: "secondary"
            ))
        }
        readings.append(contentsOf: extraReadings)

        return UsageWindowObservation(
            observedAt: now,
            accountGeneration: generation,
            accountKey: accountKey,
            accountType: accountType,
            authorization: authorization,
            readings: readings
        )
    }

    /// The earlier half of an idle pair. Its reset slid forward with the clock,
    /// which is what proves the backend is not holding a fixed window.
    static func previousIdleObservation(
        before now: Date = base,
        accountKey: String = chatgptKey,
        accountType: String = chatgptType,
        generation: Int = 1,
        authorization: UsageWindowAuthorization = .allowed
    ) -> UsageWindowObservation {
        let observedAt = now.addingTimeInterval(-60)
        return UsageWindowObservation(
            observedAt: observedAt,
            accountGeneration: generation,
            accountKey: accountKey,
            accountType: accountType,
            authorization: authorization,
            readings: [
                reading(
                    usedPercent: 0,
                    resetsAt: observedAt.addingTimeInterval(fiveHourSeconds),
                    observedAt: observedAt
                )
            ]
        )
    }

    /// The same identity as `idleObservation` but without the sliding history,
    /// so the short window is only a hypothetical candidate.
    static func candidateObservation(
        at now: Date = base,
        accountKey: String = chatgptKey,
        authorization: UsageWindowAuthorization = .allowed
    ) -> UsageWindowObservation {
        UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: accountKey,
            accountType: chatgptType,
            authorization: authorization,
            readings: [
                reading(
                    usedPercent: 0,
                    resetsAt: now.addingTimeInterval(fiveHourSeconds),
                    observedAt: now
                )
            ]
        )
    }

    static func activeObservation(
        at now: Date = base,
        usedPercent: Int = 35,
        accountKey: String = chatgptKey,
        authorization: UsageWindowAuthorization = .allowed
    ) -> UsageWindowObservation {
        UsageWindowObservation(
            observedAt: now,
            accountGeneration: 1,
            accountKey: accountKey,
            accountType: chatgptType,
            authorization: authorization,
            readings: [
                reading(
                    usedPercent: usedPercent,
                    resetsAt: now.addingTimeInterval(2 * 3_600),
                    observedAt: now
                )
            ]
        )
    }

    static func models(
        id: String = "gpt-5",
        efforts: [String] = ["low", "medium", "high"]
    ) -> [CodexModelSummary] {
        [
            CodexModelSummary(
                id: id,
                displayName: "GPT-5",
                supportedReasoningEfforts: efforts,
                defaultReasoningEffort: "medium",
                isDefault: true,
                isHidden: false
            )
        ]
    }

    static func settings(
        autoStartEnabled: Bool = true,
        modelID: String? = "gpt-5",
        reasoningEffort: String? = "low",
        activeHours: UsageWindowActiveHours = .always
    ) -> UsageWindowStartSettings {
        UsageWindowStartSettings(
            autoStartEnabled: autoStartEnabled,
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            activeHours: activeHours
        )
    }

    static func input(
        observation: UsageWindowObservation? = nil,
        previousObservation: UsageWindowObservation? = nil,
        settings: UsageWindowStartSettings? = nil,
        state: UsageWindowStartState = .empty,
        now: Date = base,
        trigger: UsageWindowStartTrigger = .automatic,
        calendar: Calendar = WindowStartFixtures.utcCalendar,
        isPreviewMode: Bool = false,
        isOperationInProgress: Bool = false,
        isAnotherInstanceActive: Bool = false,
        models: [CodexModelSummary]? = nil,
        generation: Int = 1
    ) -> UsageWindowStartEvaluationInput {
        let resolvedObservation = observation ?? idleObservation(at: now)
        let resolvedPrevious = (observation == nil && previousObservation == nil)
            ? previousIdleObservation(before: now)
            : previousObservation
        return UsageWindowStartEvaluationInput(
            observation: resolvedObservation,
            previousObservation: resolvedPrevious,
            currentAccountKey: resolvedObservation.accountKey,
            currentAccountGeneration: generation,
            currentAccountType: resolvedObservation.accountType,
            settings: settings ?? WindowStartFixtures.settings(),
            state: state,
            now: now,
            trigger: trigger,
            calendar: calendar,
            isPreviewMode: isPreviewMode,
            isOperationInProgress: isOperationInProgress,
            isAnotherInstanceActive: isAnotherInstanceActive,
            models: models ?? WindowStartFixtures.models()
        )
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// Builds a calendar pinned to a fixed local time zone for active-hours tests.
    static func calendar(timeZoneIdentifier identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
