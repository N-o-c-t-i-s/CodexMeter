import Foundation

/// Everything one ephemeral start turn needs at dispatch time.
struct WindowStartTurnPayload: Equatable, Sendable {
    let attemptID: String
    /// The account generation that authorized the send. Every stage re-checks it
    /// because `account/read` can notice an identity change without an
    /// `account/updated` notification.
    let generation: Int
    let model: String
    let effort: String
    let prompt: String
    let workDirectory: URL
}

/// Decision layer for one ephemeral start turn.
///
/// It owns the attempt bookkeeping and returns the action the transport should
/// perform rather than performing it. Keeping it free of the App Server is what
/// makes account boundaries, cancellations, and late replies testable: the app
/// target is only the executor.
struct CodexWindowTurnBridge: Equatable, Sendable {
    /// The provider a ChatGPT subscription turn is expected to resolve to. A
    /// thread bound elsewhere would be metered outside the subscription.
    static let standardProviderID = "openai"

    enum Action: Equatable, Sendable {
        /// Send `thread/start` with this payload.
        case sendThread(WindowStartTurnPayload)
        /// Send `turn/start` on the thread that reply attached.
        case sendTurn(
            attemptID: String,
            threadID: String,
            model: String,
            effort: String,
            prompt: String
        )
        /// Abandon the attempt: forget these request identifiers, interrupt the
        /// thread when one was attached, then report `result`.
        case abandon(
            requestIDs: [Int],
            threadID: String?,
            turnID: String?,
            result: WindowStartTransportResult
        )
        /// Report a terminal result without touching the transport.
        case finish(WindowStartTransportResult)
        /// A late or foreign event that must not change anything.
        case drop
    }

    private(set) var bookkeeper = CodexTurnStartBookkeeper()
    private(set) var payload: WindowStartTurnPayload?

    var isIdle: Bool { bookkeeper.isIdle }
    var activeAttemptID: String? { bookkeeper.attemptID }
    var activeGeneration: Int? { bookkeeper.generation }

    // MARK: - Starting

    mutating func begin(_ payload: WindowStartTurnPayload) -> Action {
        guard bookkeeper.begin(
            attemptID: payload.attemptID,
            generation: payload.generation
        ) else {
            return .finish(.rejected(.concurrentRequest))
        }
        self.payload = payload
        return .sendThread(payload)
    }

    mutating func threadRequestRegistered(id: Int) {
        bookkeeper.recordThreadRequest(id: id)
    }

    mutating func turnRequestRegistered(id: Int) {
        bookkeeper.recordTurnRequest(id: id)
    }

    // MARK: - Replies

    mutating func receiveThreadReply(
        requestID: Int,
        generation: Int,
        threadID: String,
        modelProvider: String?
    ) -> Action {
        // A reply from an abandoned attempt is not this attempt's thread, and one
        // from a previous account must not advance at all.
        guard bookkeeper.owns(requestID: requestID) else { return .drop }
        guard bookkeeper.accepts(generation: generation) else {
            return abandonForAccountBoundary()
        }
        guard let payload else { return abandonForAccountBoundary() }
        guard bookkeeper.acceptThreadStarted(
            threadID: threadID,
            modelProvider: modelProvider
        ) else {
            return .drop
        }

        if let modelProvider, modelProvider != Self.standardProviderID {
            return abandon(.rejected(.unsupportedAccount))
        }

        return .sendTurn(
            attemptID: payload.attemptID,
            threadID: threadID,
            model: payload.model,
            effort: payload.effort,
            prompt: payload.prompt
        )
    }

    mutating func receiveTurnReply(
        requestID: Int,
        generation: Int,
        turnID: String
    ) -> Action {
        guard bookkeeper.owns(requestID: requestID) else { return .drop }
        guard bookkeeper.accepts(generation: generation) else {
            return abandonForAccountBoundary()
        }
        bookkeeper.acceptTurnStarted(turnID: turnID)
        return .drop
    }

    mutating func receiveCompletion(
        threadID: String,
        turnID: String?,
        generation: Int,
        status: String,
        errorMessage: String?
    ) -> Action {
        guard bookkeeper.accepts(generation: generation) else {
            return abandonForAccountBoundary()
        }
        // Both the thread and, once known, the turn must name this attempt.
        guard bookkeeper.matchesCompletion(threadID: threadID, turnID: turnID) else {
            return .drop
        }

        let recordedTurnID = bookkeeper.active?.turnID ?? turnID
        let provider = bookkeeper.active?.modelProvider
        let result: WindowStartTransportResult
        switch status {
        case "completed":
            result = .completed(turnID: recordedTurnID, modelProvider: provider)
        case "interrupted":
            result = .interrupted(turnID: recordedTurnID)
        default:
            result = .turnFailed(turnID: recordedTurnID, detail: errorMessage)
        }

        _ = bookkeeper.finish()
        payload = nil
        return .finish(result)
    }

    // MARK: - Interruption

    /// The account changed. A turn that never dispatched is a clean refusal; one
    /// that already dispatched may have reached the backend, so it becomes
    /// unknown delivery and the old account keeps its recorded protection.
    mutating func accountBoundary() -> Action {
        abandonForAccountBoundary()
    }

    mutating func cancel(attemptID: String) -> Action {
        guard bookkeeper.attemptID == attemptID else { return .drop }
        return abandon(.undetermined(.cancelled))
    }

    /// A transport-side failure that ends the attempt (missing thread id, a
    /// `sendRequest` that could not write, and so on).
    mutating func fail(_ result: WindowStartTransportResult) -> Action {
        abandon(result)
    }

    // MARK: - Private

    private mutating func abandonForAccountBoundary() -> Action {
        guard let attempt = bookkeeper.finish() else {
            payload = nil
            return .drop
        }
        payload = nil
        let result: WindowStartTransportResult = attempt.turnRequestID == nil
            ? .rejected(.unsupportedAccount)
            : .undetermined(.connectionLost)
        return .abandon(
            requestIDs: [attempt.threadRequestID, attempt.turnRequestID].compactMap { $0 },
            threadID: attempt.threadID,
            turnID: attempt.turnID,
            result: result
        )
    }

    private mutating func abandon(_ result: WindowStartTransportResult) -> Action {
        guard let attempt = bookkeeper.finish() else {
            payload = nil
            return .drop
        }
        payload = nil
        return .abandon(
            requestIDs: [attempt.threadRequestID, attempt.turnRequestID].compactMap { $0 },
            threadID: attempt.threadID,
            turnID: attempt.turnID,
            result: result
        )
    }
}
