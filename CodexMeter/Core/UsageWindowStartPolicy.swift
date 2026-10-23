import Foundation

/// Every reason the window starter declines to send, encoded so the UI can
/// localize it and tests can assert on it.
///
/// `wait` reasons resolve on their own as time passes or data refreshes;
/// `blocked` reasons need the user, the backend, or a settings change.
enum UsageWindowStartBlockReason: String, Equatable, Sendable {
    // Environment
    case previewModeActive
    case operationInProgress
    case anotherInstanceActive
    case protectionStateUnavailable

    // Account
    case notLoggedIn
    case unsupportedAccountType
    case accountChanged

    // Observation
    case observationUnavailable
    case observationStale
    case standardBucketMissing
    case conflictingWindowData
    case windowMetadataInvalid

    // Backend state
    case ordinaryUsageDenied
    case ordinaryUsageUnknown
    case spendControlReached
    case rateLimitReached
    case weeklyLimitExhausted
    case weeklyResetPending

    // Window state
    case windowActive
    case windowStateUnknown
    case awaitingIdleConfirmation

    // Configuration
    case autoStartDisabled
    case outsideActiveHours
    case modelNotSelected
    case modelUnavailable
    case reasoningEffortUnavailable

    // Duplicate protection
    case coolingDown
    case confirmationPending
    case sameEpisodeAlreadySent
    case previousDeliveryUnknown
}

enum UsageWindowStartDecision: Equatable, Sendable {
    case start
    case wait(UsageWindowStartBlockReason)
    case blocked(UsageWindowStartBlockReason)

    var blockReason: UsageWindowStartBlockReason? {
        switch self {
        case .start: return nil
        case let .wait(reason): return reason
        case let .blocked(reason): return reason
        }
    }

    var isStart: Bool {
        if case .start = self { return true }
        return false
    }
}

struct UsageWindowStartEvaluation: Equatable, Sendable {
    let decision: UsageWindowStartDecision
    let activity: UsageWindowActivity

    static let unknown = UsageWindowStartEvaluation(
        decision: .blocked(.observationUnavailable),
        activity: .unknown
    )
}

/// Everything the decision depends on, supplied by the caller so the policy has
/// no clock, no I/O, and no UI state of its own.
struct UsageWindowStartEvaluationInput: Sendable {
    var observation: UsageWindowObservation
    /// The previous observation of the same account generation, used only to
    /// tell a sliding hypothetical reset from a fixed running one.
    var previousObservation: UsageWindowObservation?
    /// The account the app is authenticated as right now.
    var currentAccountKey: String
    var currentAccountGeneration: Int
    /// The account type the App Server reports, or nil while unknown.
    var currentAccountType: String?
    var settings: UsageWindowStartSettings
    var state: UsageWindowStartState
    var now: Date
    var trigger: UsageWindowStartTrigger
    var calendar: Calendar
    var isPreviewMode: Bool
    var isOperationInProgress: Bool
    var isAnotherInstanceActive: Bool
    /// Nil means the model catalog could not be read; the starter refuses
    /// rather than sending with an unverified model.
    var models: [CodexModelSummary]?
    var maximumObservationAge: TimeInterval = 60
    var cooldown: TimeInterval = 30 * 60

    static func placeholder(
        observation: UsageWindowObservation,
        now: Date
    ) -> UsageWindowStartEvaluationInput {
        UsageWindowStartEvaluationInput(
            observation: observation,
            previousObservation: nil,
            currentAccountKey: observation.accountKey,
            currentAccountGeneration: observation.accountGeneration,
            currentAccountType: observation.accountType,
            settings: .defaultValue,
            state: .empty,
            now: now,
            trigger: .automatic,
            calendar: .autoupdatingCurrent,
            isPreviewMode: false,
            isOperationInProgress: false,
            isAnotherInstanceActive: false,
            models: nil
        )
    }
}

/// A pure decision function.
///
/// The order below is the safety order: environment, account, data quality,
/// backend permission, window state, configuration, duplicate protection. Every
/// branch that cannot prove it is safe to send returns a reason instead of a
/// guess.
enum UsageWindowStartPolicy {
    static func evaluate(_ input: UsageWindowStartEvaluationInput) -> UsageWindowStartEvaluation {
        // 1. Environment that must never produce a real request.
        if input.isPreviewMode {
            return blocked(.previewModeActive)
        }
        if input.isAnotherInstanceActive {
            return blocked(.anotherInstanceActive)
        }
        if input.isOperationInProgress {
            return waiting(.operationInProgress)
        }

        // 2. Account identity must be current and complete.
        guard let accountType = input.currentAccountType, !accountType.isEmpty else {
            return blocked(.notLoggedIn)
        }
        guard accountType == "chatgpt" else {
            return blocked(.unsupportedAccountType)
        }
        guard input.observation.accountType == accountType,
              input.observation.accountKey == input.currentAccountKey,
              input.observation.accountGeneration == input.currentAccountGeneration else {
            return blocked(.accountChanged)
        }

        // 3. The decision snapshot must be fresh and structurally usable.
        if input.observation.isOlderThan(input.maximumObservationAge, now: input.now) {
            return waiting(.observationStale)
        }
        if input.observation.hasConflictingWindows {
            return blocked(.conflictingWindowData)
        }
        guard let shortWindow = input.observation.shortWindow else {
            return blocked(.standardBucketMissing)
        }
        guard (0...100).contains(shortWindow.usedPercent),
              shortWindow.durationMins == UsageWindowObservation.shortWindowDurationMins,
              shortWindow.resetsAt != nil else {
            return blocked(.windowMetadataInvalid)
        }

        // 4. Backend permission outranks any local inference.
        switch input.observation.authorization {
        case .denied:
            return blocked(.ordinaryUsageDenied)
        case .unknown:
            return blocked(.ordinaryUsageUnknown)
        case .allowed:
            break
        }
        if shortWindow.spendControlReached == true {
            return blocked(.spendControlReached)
        }
        if let reached = shortWindow.rateLimitReachedType, !reached.isEmpty {
            return blocked(.rateLimitReached)
        }

        // 5. An exhausted weekly limit outranks a short-window idle reading.
        let weekly = input.observation.weeklyWindow
        if let weekly {
            guard (0...100).contains(weekly.usedPercent) else {
                return blocked(.windowMetadataInvalid)
            }
            if weekly.usedPercent >= 100 {
                if let resetsAt = weekly.resetsAt, resetsAt <= input.now {
                    return waiting(.weeklyResetPending)
                }
                return waiting(.weeklyLimitExhausted)
            }
        }

        // 6. The short window itself must be provably idle.
        let assessment = UsageWindowActivityClassifier.assess(
            current: shortWindow,
            previous: previousShortWindow(of: input),
            at: input.now
        )

        switch assessment.activity {
        case .active:
            return UsageWindowStartEvaluation(decision: .wait(.windowActive), activity: .active)
        case .unknown:
            if assessment.isHypotheticalCandidate {
                return UsageWindowStartEvaluation(
                    decision: .wait(.awaitingIdleConfirmation),
                    activity: .unknown
                )
            }
            return UsageWindowStartEvaluation(
                decision: .blocked(.windowStateUnknown),
                activity: .unknown
            )
        case .idle:
            break
        }

        // 7. Configuration. A manual request may ignore the switch and the time
        // range but still needs a valid model and effort.
        if input.trigger == .automatic {
            guard input.settings.autoStartEnabled else {
                return decided(.blocked(.autoStartDisabled), activity: .idle)
            }
            guard input.settings.activeHours.contains(input.now, calendar: input.calendar) else {
                return decided(.wait(.outsideActiveHours), activity: .idle)
            }
        }

        guard let modelID = input.settings.modelID else {
            return decided(.blocked(.modelNotSelected), activity: .idle)
        }
        guard let models = input.models else {
            return decided(.blocked(.modelUnavailable), activity: .idle)
        }
        guard let model = models.first(where: { $0.id == modelID }) else {
            return decided(.blocked(.modelUnavailable), activity: .idle)
        }
        guard UsageWindowReasoningPreference.resolved(
            stored: input.settings.reasoningEffort,
            model: model
        ) != nil else {
            return decided(.blocked(.reasoningEffortUnavailable), activity: .idle)
        }

        // 8. Duplicate protection. An open episode never resends until the
        // window it started has been observed running and then ended.
        if let duplicate = duplicateProtection(input, activity: .idle) {
            return duplicate
        }

        return UsageWindowStartEvaluation(decision: .start, activity: .idle)
    }

    /// The read-only part of the decision used when nothing will be sent but the
    /// UI still wants to show whether a window is running.
    static func activity(
        observation: UsageWindowObservation,
        previousObservation: UsageWindowObservation?,
        now: Date
    ) -> UsageWindowActivity {
        guard let shortWindow = observation.shortWindow else { return .unknown }
        return UsageWindowActivityClassifier.assess(
            current: shortWindow,
            previous: previousObservation?.shortWindow,
            at: now
        ).activity
    }

    private static func duplicateProtection(
        _ input: UsageWindowStartEvaluationInput,
        activity: UsageWindowActivity
    ) -> UsageWindowStartEvaluation? {
        let state = input.state

        if state.episodeOpen || state.blocksNewAttempt {
            switch state.lastOutcomeCode {
            case .deliveryUnknown?:
                return decided(.blocked(.previousDeliveryUnknown), activity: activity)
            case .unconfirmed?:
                return decided(.wait(.sameEpisodeAlreadySent), activity: activity)
            case .failed?:
                // A provable failure closed the episode; only the cooldown applies.
                break
            default:
                if state.phase == .awaitingConfirmation || state.phase == .sending {
                    return decided(.wait(.confirmationPending), activity: activity)
                }
                return decided(.wait(.sameEpisodeAlreadySent), activity: activity)
            }
        }

        if let lastSentAt = state.lastSentAt {
            let elapsed = input.now.timeIntervalSince(lastSentAt)
            if elapsed < input.cooldown {
                return decided(.wait(.coolingDown), activity: activity)
            }
        }

        return nil
    }

    private static func previousShortWindow(
        of input: UsageWindowStartEvaluationInput
    ) -> UsageWindowReading? {
        guard let previous = input.previousObservation,
              previous.accountGeneration == input.currentAccountGeneration,
              previous.accountKey == input.currentAccountKey else {
            return nil
        }
        return previous.shortWindow
    }

    private static func blocked(
        _ reason: UsageWindowStartBlockReason
    ) -> UsageWindowStartEvaluation {
        UsageWindowStartEvaluation(decision: .blocked(reason), activity: .unknown)
    }

    private static func waiting(
        _ reason: UsageWindowStartBlockReason
    ) -> UsageWindowStartEvaluation {
        UsageWindowStartEvaluation(decision: .wait(reason), activity: .unknown)
    }

    private static func decided(
        _ decision: UsageWindowStartDecision,
        activity: UsageWindowActivity
    ) -> UsageWindowStartEvaluation {
        UsageWindowStartEvaluation(decision: decision, activity: activity)
    }
}
