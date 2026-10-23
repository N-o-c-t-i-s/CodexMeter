import Foundation

/// Binds the JSON-RPC requests of one ephemeral turn to the attempt that issued
/// them.
///
/// A timed-out or cancelled attempt can still have a `thread/start` reply in
/// flight. Without this bookkeeping that reply is indistinguishable from the
/// replacement attempt's reply, and the bridge would open a second turn on a
/// thread the caller already gave up on. `cancel()` reports the request
/// identifiers that must be forgotten so their late replies are dropped.
struct CodexTurnStartBookkeeper: Equatable, Sendable {
    struct Attempt: Equatable, Sendable {
        let attemptID: String
        let generation: Int
        var threadRequestID: Int?
        var turnRequestID: Int?
        var threadID: String?
        var turnID: String?
        var modelProvider: String?
    }

    private(set) var active: Attempt?

    var isIdle: Bool { active == nil }

    /// Claims the single in-flight slot. Returns false when one is already held.
    mutating func begin(attemptID: String, generation: Int) -> Bool {
        guard active == nil else { return false }
        active = Attempt(attemptID: attemptID, generation: generation)
        return true
    }

    mutating func recordThreadRequest(id: Int) {
        active?.threadRequestID = id
    }

    mutating func recordTurnRequest(id: Int) {
        active?.turnRequestID = id
    }

    func owns(requestID: Int) -> Bool {
        guard let active else { return false }
        return active.threadRequestID == requestID || active.turnRequestID == requestID
    }

    /// True while the slot belongs to the account generation the caller is on.
    ///
    /// A recorded generation that is never compared makes an account switch
    /// undetectable, so every stage of the turn checks it before advancing.
    func accepts(generation: Int) -> Bool {
        active?.generation == generation
    }

    var generation: Int? { active?.generation }

    var attemptID: String? { active?.attemptID }

    /// True once a turn was dispatched, meaning the request may already have
    /// reached the backend.
    var hasDispatchedTurn: Bool { active?.turnRequestID != nil }

    /// Attaches the thread only when the active attempt has not attached one yet,
    /// so a late reply from a superseded attempt cannot hijack the current one.
    @discardableResult
    mutating func acceptThreadStarted(threadID: String, modelProvider: String?) -> Bool {
        guard var attempt = active, attempt.threadID == nil else { return false }
        attempt.threadID = threadID
        attempt.modelProvider = modelProvider
        active = attempt
        return true
    }

    @discardableResult
    mutating func acceptTurnStarted(turnID: String) -> Bool {
        guard var attempt = active, attempt.threadID != nil else { return false }
        attempt.turnID = turnID
        active = attempt
        return true
    }

    /// A completion must name this attempt's thread, and its turn when the
    /// attempt already knows the turn identifier.
    func matchesCompletion(threadID: String, turnID: String?) -> Bool {
        guard let attempt = active, attempt.threadID == threadID else { return false }
        if let knownTurnID = attempt.turnID, let turnID, knownTurnID != turnID {
            return false
        }
        return true
    }

    /// Clears the slot and returns the request identifiers still outstanding.
    ///
    /// The caller removes these from its pending-request table so a late reply is
    /// dropped before it can be attributed to a newer attempt.
    mutating func cancel() -> [Int] {
        guard let attempt = finish() else { return [] }
        return [attempt.threadRequestID, attempt.turnRequestID].compactMap { $0 }
    }

    /// Cancels only when `attemptID` still owns the slot, so an abandoned
    /// attempt cannot clear its replacement.
    mutating func cancel(attemptID: String) -> [Int] {
        guard active?.attemptID == attemptID else { return [] }
        return cancel()
    }

    /// Clears the slot only when `attemptID` still owns it.
    mutating func finishIfOwned(by attemptID: String) -> Attempt? {
        guard active?.attemptID == attemptID else { return nil }
        return finish()
    }

    /// Clears the slot after a terminal result and returns what was recorded.
    mutating func finish() -> Attempt? {
        defer { active = nil }
        return active
    }
}
