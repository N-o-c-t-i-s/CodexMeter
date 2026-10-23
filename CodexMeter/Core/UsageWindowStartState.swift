import Foundation

/// What the window starter is doing right now, or last settled on.
///
/// `checking` and `sending` are transient UI phases. The persisted values that
/// matter for duplicate protection are `awaitingConfirmation` and the outcome
/// states below it.
enum UsageWindowStartPhase: String, Codable, Equatable, Sendable {
    case idle
    case checking
    case sending
    case awaitingConfirmation
    case confirmed
    case unconfirmed
    case failed
}

/// A stable, localized-at-display-time code for the last settled result.
enum UsageWindowStartOutcomeCode: String, Codable, Equatable, Sendable {
    /// A window was observed running after the send.
    case confirmed
    /// The request completed but no fixed new window was observed in time.
    case unconfirmed
    /// The request may have reached the backend; delivery cannot be proven.
    case deliveryUnknown
    /// The request provably did not start a window.
    case failed
}

/// Why a send produced its outcome, bounded and free of model output, prompts,
/// stderr tails, account identity, or authentication material.
enum UsageWindowStartFailureCode: String, Codable, Equatable, Sendable {
    case notAuthenticated
    case unsupportedAccount
    case modelRejected
    case timeout
    case connectionLost
    case cancelled
    case transportError
    case turnFailed
    case turnInterrupted
    case concurrentRequest
}

/// Persisted duplicate protection for one account.
///
/// A reservation is written before the request leaves the app so a crash
/// between "sent" and "recorded" cannot produce a second send on relaunch.
struct UsageWindowStartState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var phase: UsageWindowStartPhase
    var attemptID: String?
    /// Written before the request is dispatched, never after.
    var reservedAt: Date?
    var lastSentAt: Date?
    var lastCompletedAt: Date?
    var lastConfirmedAt: Date?
    /// The `limitID:duration` the send targeted, for diagnostics only.
    var targetWindowIdentity: String?
    /// True from the moment a reservation is written until a window has been
    /// observed running and then observed to end.
    var episodeOpen: Bool
    var lastOutcomeCode: UsageWindowStartOutcomeCode?
    var lastFailureCode: UsageWindowStartFailureCode?
    var lastOutcomeAt: Date?
    /// `lastSentAt + confirmationDelay`, persisted so a relaunch still resolves
    /// an in-flight confirmation instead of resending.
    var confirmationDeadline: Date?
    /// True once a running window was observed during the current episode. The
    /// episode closes only after that window is seen to end.
    var windowObservedRunning: Bool

    static let empty = UsageWindowStartState(
        phase: .idle,
        attemptID: nil,
        reservedAt: nil,
        lastSentAt: nil,
        lastCompletedAt: nil,
        lastConfirmedAt: nil,
        targetWindowIdentity: nil,
        episodeOpen: false,
        lastOutcomeCode: nil,
        lastFailureCode: nil,
        lastOutcomeAt: nil,
        confirmationDeadline: nil,
        windowObservedRunning: false
    )

    /// True while an attempt reserves the right to send and has not been
    /// resolved by observing a window run and end.
    var blocksNewAttempt: Bool {
        episodeOpen || phase == .awaitingConfirmation || phase == .sending
    }
}

/// The persisted record for one local account key.
struct UsageWindowStartAccountRecord: Codable, Equatable, Sendable {
    var settings: UsageWindowStartSettings
    var state: UsageWindowStartState
    var updatedAt: Date

    static func empty(at date: Date) -> UsageWindowStartAccountRecord {
        UsageWindowStartAccountRecord(
            settings: .defaultValue,
            state: .empty,
            updatedAt: date
        )
    }
}

/// The versioned on-disk document.
struct UsageWindowStartPersistedState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    /// Bounded so an installation cannot grow this file without limit.
    static let maximumAccounts = 8

    var schemaVersion: Int
    var accounts: [String: UsageWindowStartAccountRecord]

    static let empty = UsageWindowStartPersistedState(
        schemaVersion: currentSchemaVersion,
        accounts: [:]
    )

    func record(for accountKey: String) -> UsageWindowStartAccountRecord {
        accounts[accountKey] ?? .empty(at: Date(timeIntervalSince1970: 0))
    }

    /// Drops the least recently touched accounts once the cap is exceeded.
    mutating func pruneAccounts() {
        guard accounts.count > Self.maximumAccounts else { return }
        let ordered = accounts.sorted { $0.value.updatedAt > $1.value.updatedAt }
        let keep = Set(ordered.prefix(Self.maximumAccounts).map(\.key))
        accounts = accounts.filter { keep.contains($0.key) }
    }
}
