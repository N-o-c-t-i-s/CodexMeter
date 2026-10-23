import Foundation

/// Pure state transitions for duplicate protection.
///
/// Keeping these out of the coordinator is what makes a crash between "reserved"
/// and "sent", an unknown delivery, and a confirmation timeout testable without
/// a running App Server.
enum UsageWindowStartTransitions {
    /// Writes the reservation that must exist before the request leaves the app.
    ///
    /// The episode opens here, not after the response: a crash between dispatch
    /// and the answer must not look like "never sent" on the next launch.
    static func reserve(
        _ state: inout UsageWindowStartState,
        attemptID: String,
        now: Date,
        confirmationDelay: TimeInterval,
        windowIdentity: String?
    ) {
        state.phase = .sending
        state.attemptID = attemptID
        state.reservedAt = now
        state.targetWindowIdentity = windowIdentity
        state.episodeOpen = true
        state.windowObservedRunning = false
        state.confirmationDeadline = now.addingTimeInterval(confirmationDelay)
        state.lastOutcomeCode = nil
        state.lastFailureCode = nil
        state.lastOutcomeAt = nil
    }

    /// Applies the runner's terminal result.
    ///
    /// A delivered turn stays `awaitingConfirmation`: arrival is proven, a new
    /// window is not. A provable refusal closes the episode because nothing
    /// reached the backend. Anything ambiguous keeps the episode open.
    static func apply(
        _ outcome: WindowStartOutcome,
        to state: inout UsageWindowStartState,
        now: Date
    ) {
        state.lastSentAt = now
        state.lastCompletedAt = now
        state.lastOutcomeAt = now

        switch outcome {
        case .delivered:
            state.phase = .awaitingConfirmation
            state.episodeOpen = true
            state.lastOutcomeCode = nil
            state.lastFailureCode = nil

        case let .failed(code):
            state.phase = .failed
            state.episodeOpen = false
            state.windowObservedRunning = false
            state.lastOutcomeCode = .failed
            state.lastFailureCode = code
            state.confirmationDeadline = nil

        case let .deliveryUnknown(code):
            state.phase = .failed
            // Delivery is unknown, so the duplicate guard must stay up until the
            // user explicitly clears it or a window is observed running.
            state.episodeOpen = true
            state.lastOutcomeCode = .deliveryUnknown
            state.lastFailureCode = code
        }
    }

    /// Reconciles a fresh observation with the recorded attempt.
    ///
    /// Returns true when the persisted record changed.
    @discardableResult
    static func reconcile(
        activity: UsageWindowActivity,
        state: inout UsageWindowStartState,
        now: Date,
        observedAt: Date? = nil
    ) -> Bool {
        guard state.episodeOpen else { return false }

        switch activity {
        case .active:
            guard !state.windowObservedRunning
                || state.phase != .confirmed
                || state.lastOutcomeCode != .confirmed else {
                return false
            }
            state.windowObservedRunning = true
            // A window is running. Attribution stays descriptive: it may also be
            // the user's own activity.
            state.phase = .confirmed
            state.lastOutcomeCode = .confirmed
            state.lastConfirmedAt = now
            state.lastOutcomeAt = now
            state.confirmationDeadline = nil
            return true

        case .idle:
            if !state.windowObservedRunning {
                // Periodic reads must also settle a delivered attempt after the
                // bounded confirmation retries stop, even with automation off.
                guard state.phase == .awaitingConfirmation,
                      let deadline = state.confirmationDeadline,
                      let observedAt,
                      observedAt >= deadline,
                      observedAt <= now,
                      now.timeIntervalSince(observedAt) <= 60 else {
                    return false
                }
                confirm(&state, confirmed: false, now: now)
                return true
            }
            // The window this episode started has ended, so a new episode may
            // begin once the cooldown has passed.
            state.windowObservedRunning = false
            state.episodeOpen = false
            state.phase = .confirmed
            state.lastOutcomeCode = .confirmed
            state.lastOutcomeAt = now
            return true

        case .unknown:
            return false
        }
    }

    /// Settles a confirmation deadline.
    static func confirm(
        _ state: inout UsageWindowStartState,
        confirmed: Bool,
        now: Date
    ) {
        state.lastOutcomeAt = now
        state.confirmationDeadline = nil

        if confirmed {
            state.phase = .confirmed
            state.lastOutcomeCode = .confirmed
            state.lastConfirmedAt = now
            state.windowObservedRunning = true
        } else {
            state.phase = .unconfirmed
            state.lastOutcomeCode = .unconfirmed
            // The episode stays open: an unconfirmed send may still have started
            // a window, so a cooldown alone must not authorize another one.
            state.episodeOpen = true
        }
    }

    /// The explicit user action that clears an unresolved protection. It is not
    /// a resend: it only allows a future evaluation to send again.
    static func clearProtection(_ state: inout UsageWindowStartState) {
        state.phase = .idle
        state.attemptID = nil
        state.reservedAt = nil
        state.lastOutcomeCode = nil
        state.lastFailureCode = nil
        state.lastOutcomeAt = nil
        state.confirmationDeadline = nil
        state.targetWindowIdentity = nil
        state.episodeOpen = false
        state.windowObservedRunning = false
        // lastSentAt is kept so the ordinary cooldown still applies.
    }

    /// True when the persisted record still believes a request is in flight.
    static func hasUnresolvedAttempt(_ state: UsageWindowStartState) -> Bool {
        state.phase == .sending
            || state.episodeOpen
            || state.phase == .awaitingConfirmation
    }
}
