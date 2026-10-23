import Foundation

/// One minimal request intended to start the next usage window.
struct WindowStartRequest: Equatable, Sendable {
    /// The shortest prompt that still produces a real model turn.
    static let defaultPrompt = "Reply with just: ok"

    let modelID: String
    let reasoningEffort: String
    let prompt: String
    let timeout: TimeInterval
    /// Ties this request to the reservation that authorized it. The transport
    /// uses it to bind its JSON-RPC requests to the same attempt.
    let attemptID: String

    init(
        modelID: String,
        reasoningEffort: String,
        prompt: String = WindowStartRequest.defaultPrompt,
        timeout: TimeInterval = 120,
        attemptID: String = ""
    ) {
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.prompt = prompt
        self.timeout = timeout
        self.attemptID = attemptID
    }
}

/// What the transport observed. Kept separate from the runner's outcome so the
/// transport can stay a thin protocol adapter.
enum WindowStartTransportResult: Equatable, Sendable {
    /// The backend completed the turn. This proves the message was delivered,
    /// never that a new window started.
    case completed(turnID: String?, modelProvider: String?)
    /// The turn started and then failed on the backend.
    case turnFailed(turnID: String?, detail: String?)
    /// The turn was interrupted before completion.
    case interrupted(turnID: String?)
    /// The backend refused the request before processing it.
    case rejected(UsageWindowStartFailureCode)
    /// Nothing conclusive was observed.
    case undetermined(UsageWindowStartFailureCode)
}

/// The narrow seam that lets the start request be replaced by a fake.
///
/// The shipping implementation drives the already authenticated Codex App
/// Server connection, so the request inherits exactly the identity, provider,
/// and `CODEX_HOME` the quota observation came from.
protocol WindowStartTransport: AnyObject {
    func startEphemeralTurn(
        _ request: WindowStartRequest,
        completion: @escaping (WindowStartTransportResult) -> Void
    )
    /// Best-effort interrupt of one attempt.
    ///
    /// The identifier is mandatory: an unconditional cancel lets an abandoned
    /// attempt interrupt the request that replaced it, because the abandoned
    /// completion can legitimately start that replacement.
    func cancelPendingTurn(attemptID: String)
}

enum WindowStartOutcome: Equatable, Sendable {
    /// The turn completed. Arrival is proven; a started window is not.
    case delivered(turnID: String?, modelProvider: String?)
    /// The request provably did not start a window.
    case failed(UsageWindowStartFailureCode)
    /// The request may have reached the backend. Duplicate protection must be
    /// kept, because no further send is safe.
    case deliveryUnknown(UsageWindowStartFailureCode)
}

protocol WindowStartRunning: AnyObject {
    func start(_ request: WindowStartRequest, completion: @escaping (WindowStartOutcome) -> Void)
    func cancel()
}

/// Executes exactly one start request. Scheduling, reservation, and
/// confirmation belong to the service.
///
/// Every resolution path is serialized on the main queue and stamped with the
/// attempt token that armed it, so a late callback, a late timeout, or a cancel
/// aimed at an abandoned attempt can never settle or interrupt its replacement.
final class CodexWindowStartRunner: WindowStartRunning {
    static let defaultTimeout: TimeInterval = 120

    private struct Pending {
        let token: UUID
        let attemptID: String
        let completion: (WindowStartOutcome) -> Void
    }

    private let transport: WindowStartTransport
    private let lock = NSLock()
    private var pending: Pending?
    private var timeoutWorkItem: DispatchWorkItem?

    init(transport: WindowStartTransport) {
        self.transport = transport
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    func start(
        _ request: WindowStartRequest,
        completion: @escaping (WindowStartOutcome) -> Void
    ) {
        guard Self.isValid(request) else {
            completion(.failed(.transportError))
            return
        }

        let token = UUID()
        lock.lock()
        guard pending == nil else {
            lock.unlock()
            // Mutual exclusion is enforced above this layer; reaching here means
            // a caller bypassed it, and nothing was dispatched.
            completion(.failed(.concurrentRequest))
            return
        }
        pending = Pending(
            token: token,
            attemptID: request.attemptID,
            completion: completion
        )
        lock.unlock()

        scheduleTimeout(for: request, token: token)

        transport.startEphemeralTurn(request) { [weak self] result in
            self?.finish(Self.outcome(for: result), token: token)
        }
    }

    func cancel() {
        guard let taken = takeAnyPending() else { return }
        // Interrupt first, then report: the completion is allowed to start a
        // replacement, which must not inherit this cancel.
        transport.cancelPendingTurn(attemptID: taken.attemptID)
        taken.completion(.deliveryUnknown(.cancelled))
    }

    /// Resolves the in-flight request exactly once and only for the attempt that
    /// armed it.
    private func finish(_ outcome: WindowStartOutcome, token: UUID) {
        guard let taken = takePending(token: token) else { return }
        taken.completion(outcome)
    }

    /// Atomically claims and clears the slot for `token`. Returns nil when the
    /// token no longer owns it, so the caller can tell whether it really ended
    /// that attempt.
    private func takePending(token: UUID) -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        guard let pending, pending.token == token else { return nil }
        self.pending = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        return pending
    }

    private func takeAnyPending() -> Pending? {
        lock.lock()
        defer { lock.unlock() }
        guard let pending else { return nil }
        self.pending = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        return pending
    }

    private func scheduleTimeout(for request: WindowStartRequest, token: UUID) {
        let timeout = max(0.001, request.timeout)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let taken = self.takePending(token: token) else { return }
            // The server may have accepted the turn already, so interrupt this
            // attempt rather than pretending the request never happened. The
            // interrupt happens before the completion because the completion may
            // immediately start a replacement.
            self.transport.cancelPendingTurn(attemptID: taken.attemptID)
            taken.completion(.deliveryUnknown(.timeout))
        }

        lock.lock()
        timeoutWorkItem = workItem
        lock.unlock()

        // The main queue is the only place the transport's pending state is
        // mutated, so the timeout must not race it from a background queue.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private static func outcome(for result: WindowStartTransportResult) -> WindowStartOutcome {
        switch result {
        case let .completed(turnID, provider):
            return .delivered(turnID: turnID, modelProvider: provider)
        case .turnFailed:
            // The backend accepted and ran a turn, so a window may have started.
            return .deliveryUnknown(.turnFailed)
        case .interrupted:
            return .deliveryUnknown(.turnInterrupted)
        case let .rejected(code):
            return .failed(code)
        case let .undetermined(code):
            return .deliveryUnknown(code)
        }
    }

    private static func isValid(_ request: WindowStartRequest) -> Bool {
        !request.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !request.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !request.prompt.isEmpty
            && request.timeout > 0
    }
}
