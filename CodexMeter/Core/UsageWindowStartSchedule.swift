import Foundation

enum UsageWindowStartDeadlineReason: String, Equatable, Sendable {
    /// The running short window resets; ask again shortly after.
    case windowReset
    /// An exhausted weekly window resets.
    case weeklyReset
    /// The daily automatic window opens.
    case activeHoursStart
    /// A sent request is due for confirmation.
    case confirmation
    /// The duplicate-protection cooldown ends.
    case cooldownEnd
}

struct UsageWindowStartDeadline: Equatable, Sendable {
    let date: Date
    let reason: UsageWindowStartDeadlineReason
    /// True while the backend has not yet reflected a reset, so this is a bounded
    /// read-only recheck rather than a scheduled event. Repeats are capped by
    /// `UsageWindowStartSchedule.maximumStaleRetries`.
    let isRetry: Bool

    init(date: Date, reason: UsageWindowStartDeadlineReason, isRetry: Bool = false) {
        self.date = date
        self.reason = reason
        self.isRetry = isRetry
    }
}

/// Computes when the coordinator should look again. Pure so timer behavior can
/// be tested with explicit clocks instead of real waits.
enum UsageWindowStartSchedule {
    /// Codex reports reset times to the second; a short grace avoids asking
    /// before the backend has actually rolled the window.
    static let resetGrace: TimeInterval = 30
    /// A new window is indistinguishable from the hypothetical one right after
    /// it starts, so confirmation waits long enough for the reset to fall behind.
    static let confirmationDelay: TimeInterval = 90
    /// Minimum spacing between sends for one account.
    static let cooldown: TimeInterval = 30 * 60
    /// Bounded read-only retries while a stale snapshot has not updated.
    static let maximumStaleRetries = 5
    static let staleRetryDelay: TimeInterval = 60

    static func deadlines(
        observation: UsageWindowObservation?,
        settings: UsageWindowStartSettings,
        state: UsageWindowStartState,
        now: Date,
        calendar: Calendar
    ) -> [UsageWindowStartDeadline] {
        var deadlines: [UsageWindowStartDeadline] = []

        if let observation, let shortWindow = observation.shortWindow, let resetsAt = shortWindow.resetsAt {
            if resetsAt > now {
                deadlines.append(UsageWindowStartDeadline(
                    date: resetsAt.addingTimeInterval(resetGrace),
                    reason: .windowReset
                ))
            } else {
                // Past its reset but still reported as running: re-read on the
                // bounded retry cadence instead of a tight loop.
                deadlines.append(UsageWindowStartDeadline(
                    date: now.addingTimeInterval(staleRetryDelay),
                    reason: .windowReset,
                    isRetry: true
                ))
            }
        }

        if let weekly = observation?.weeklyWindow,
           weekly.usedPercent >= 100,
           let resetsAt = weekly.resetsAt {
            let resetDate = resetsAt.addingTimeInterval(resetGrace)
            deadlines.append(UsageWindowStartDeadline(
                date: max(now.addingTimeInterval(staleRetryDelay), resetDate),
                reason: .weeklyReset,
                isRetry: resetDate <= now
            ))
        }

        if settings.autoStartEnabled,
           let boundary = settings.activeHours.nextBoundary(after: now, calendar: calendar),
           settings.activeHours.contains(boundary, calendar: calendar) {
            deadlines.append(UsageWindowStartDeadline(date: boundary, reason: .activeHoursStart))
        }

        if let confirmationDeadline = state.confirmationDeadline, confirmationDeadline > now {
            deadlines.append(UsageWindowStartDeadline(
                date: confirmationDeadline,
                reason: .confirmation
            ))
        }

        if let lastSentAt = state.lastSentAt {
            let cooldownEnd = lastSentAt.addingTimeInterval(cooldown)
            if cooldownEnd > now {
                deadlines.append(UsageWindowStartDeadline(date: cooldownEnd, reason: .cooldownEnd))
            }
        }

        return deadlines.sorted { $0.date < $1.date }
    }

    static func nextDeadline(
        observation: UsageWindowObservation?,
        settings: UsageWindowStartSettings,
        state: UsageWindowStartState,
        now: Date,
        calendar: Calendar
    ) -> UsageWindowStartDeadline? {
        deadlines(
            observation: observation,
            settings: settings,
            state: state,
            now: now,
            calendar: calendar
        ).first { $0.date > now }
    }
}
