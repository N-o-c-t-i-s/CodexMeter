import Foundation

/// The result of asking the store for permission to send.
enum UsageWindowStartReservationOutcome: Equatable, Sendable {
    case reserved(
        attemptID: String,
        state: UsageWindowStartState,
        settings: UsageWindowStartSettings
    )
    case rejected(UsageWindowStartBlockReason)
    case unavailable(UsageWindowStartStoreError)
}

/// Everything the in-lock decision needs that does not live on disk.
struct UsageWindowStartReservationRequest: Sendable {
    let accountKey: String
    let observation: UsageWindowObservation
    let previousObservation: UsageWindowObservation?
    /// The account the app is authenticated as right now. Supplied by the caller
    /// rather than read from the observation, because an observation validating
    /// itself can never detect that it belongs to a previous account.
    let currentAccountGeneration: Int
    let currentAccountType: String?
    let models: [CodexModelSummary]?
    let now: Date
    let calendar: Calendar
    let trigger: UsageWindowStartTrigger
    let isPreviewMode: Bool
}

/// Performs the whole "decide and occupy" step inside one store transaction.
///
/// The earlier design decided in memory and then wrote the result, which let two
/// running copies both pass their own stale check and both reserve. Loading the
/// record, re-evaluating the policy, and writing the reservation under the same
/// lock closes that window: the second instance now sees the first instance's
/// open episode and is rejected.
enum UsageWindowStartReserver {
    static func reserve(
        store: UsageWindowStartStore,
        request: UsageWindowStartReservationRequest,
        attemptID: @autoclosure () -> String = UUID().uuidString
    ) -> UsageWindowStartReservationOutcome {
        do {
            return try store.transaction { document in
                // The persisted record, not the caller's copy, is authoritative.
                var record = document.record(for: request.accountKey)

                let input = UsageWindowStartEvaluationInput(
                    observation: request.observation,
                    previousObservation: request.previousObservation,
                    currentAccountKey: request.accountKey,
                    currentAccountGeneration: request.currentAccountGeneration,
                    currentAccountType: request.currentAccountType,
                    settings: record.settings,
                    state: record.state,
                    now: request.now,
                    trigger: request.trigger,
                    calendar: request.calendar,
                    isPreviewMode: request.isPreviewMode,
                    // Holding the lock means no other instance is inside a
                    // transaction, and its reservation is visible below.
                    isOperationInProgress: false,
                    isAnotherInstanceActive: false,
                    models: request.models
                )

                let evaluation = UsageWindowStartPolicy.evaluate(input)
                guard evaluation.decision == .start else {
                    return .rejected(evaluation.decision.blockReason ?? .windowStateUnknown)
                }

                let identifier = attemptID()
                var reserved = record.state
                UsageWindowStartTransitions.reserve(
                    &reserved,
                    attemptID: identifier,
                    now: request.now,
                    confirmationDelay: UsageWindowStartSchedule.confirmationDelay,
                    windowIdentity: request.observation.shortWindow?.windowIdentity
                )
                record.state = reserved
                record.updatedAt = request.now
                document.accounts[request.accountKey] = record

                return .reserved(
                    attemptID: identifier,
                    state: reserved,
                    settings: record.settings
                )
            }
        } catch let error as UsageWindowStartStoreError {
            return .unavailable(error)
        } catch {
            return .unavailable(.writeFailed)
        }
    }
}

/// What a follow-up write did.
enum UsageWindowStartWriteResult: Equatable, Sendable {
    case written(UsageWindowStartState)
    /// A newer attempt owns the record now; the caller's write was dropped.
    case superseded
    case unavailable(UsageWindowStartStoreError)
}

/// Attempt-scoped writes for a send that already left the app.
///
/// A cancelled attempt can still deliver a late outcome, a late confirmation
/// read, or a late reconciliation. Without the attempt identity those writes
/// would land on whichever attempt now owns the record, so every mutation of an
/// attempt's state compares the stored identifier first.
enum UsageWindowStartWrites {
    static func applySendOutcome(
        _ outcome: WindowStartOutcome,
        attemptID: String,
        store: UsageWindowStartStore,
        accountKey: String,
        now: Date
    ) -> UsageWindowStartWriteResult {
        mutate(store: store, accountKey: accountKey, now: now) { record in
            guard record.state.attemptID == attemptID else {
                return .superseded
            }
            UsageWindowStartTransitions.apply(outcome, to: &record.state, now: now)
            return .written(record.state)
        }
    }

    static func settleConfirmation(
        attemptID: String,
        confirmed: Bool,
        store: UsageWindowStartStore,
        accountKey: String,
        now: Date
    ) -> UsageWindowStartWriteResult {
        mutate(store: store, accountKey: accountKey, now: now) { record in
            guard record.state.attemptID == attemptID else {
                return .superseded
            }
            UsageWindowStartTransitions.confirm(&record.state, confirmed: confirmed, now: now)
            return .written(record.state)
        }
    }

    /// Reconciliation is observational rather than attempt-scoped: a window that
    /// is running proves the episode advanced no matter who asked.
    static func reconcile(
        activity: UsageWindowActivity,
        store: UsageWindowStartStore,
        accountKey: String,
        now: Date,
        observedAt: Date? = nil
    ) -> UsageWindowStartWriteResult {
        mutate(store: store, accountKey: accountKey, now: now) { record in
            guard UsageWindowStartTransitions.reconcile(
                activity: activity,
                state: &record.state,
                now: now,
                observedAt: observedAt
            ) else {
                return .written(record.state)
            }
            return .written(record.state)
        }
    }

    static func clearProtection(
        store: UsageWindowStartStore,
        accountKey: String,
        now: Date
    ) -> UsageWindowStartWriteResult {
        mutate(store: store, accountKey: accountKey, now: now) { record in
            UsageWindowStartTransitions.clearProtection(&record.state)
            return .written(record.state)
        }
    }

    private static func mutate(
        store: UsageWindowStartStore,
        accountKey: String,
        now: Date,
        _ body: (inout UsageWindowStartAccountRecord) -> UsageWindowStartWriteResult
    ) -> UsageWindowStartWriteResult {
        do {
            return try store.transaction { document in
                var record = document.record(for: accountKey)
                let result = body(&record)
                if case .written = result {
                    record.updatedAt = now
                    document.accounts[accountKey] = record
                }
                return result
            }
        } catch let error as UsageWindowStartStoreError {
            return .unavailable(error)
        } catch {
            return .unavailable(.writeFailed)
        }
    }
}
