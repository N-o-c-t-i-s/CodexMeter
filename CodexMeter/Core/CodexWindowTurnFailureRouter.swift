import Foundation

/// Which ephemeral-turn request failed.
enum CodexWindowTurnRequestKind: Equatable, Sendable {
    /// The backend answered `thread/start` with an error.
    case threadStart
    /// The backend answered `turn/start` with an error.
    case turnStart
    /// The App Server child process exited.
    case processExited
    /// The connection was re-created after a stall.
    case transportReset
}

/// Translates a failed request into the bridge's terminal action.
///
/// This lives in Core because the app target's dispatch switch is otherwise
/// untested. A branch that reports the failure without calling `fail(...)` leaves
/// the bridge occupied, so every later attempt is refused as a concurrent
/// request even after the original failure is long gone.
enum CodexWindowTurnFailureRouter {
    static func action(
        for kind: CodexWindowTurnRequestKind,
        backendMessage: String? = nil,
        bridge: inout CodexWindowTurnBridge
    ) -> CodexWindowTurnBridge.Action {
        switch kind {
        case .threadStart, .turnStart:
            // A structured error response is a refusal: the request was not
            // processed, so no window can have started and the attempt may be
            // retried once the business conditions allow it again.
            let code = failureCode(forBackendMessage: backendMessage ?? "")
            return bridge.fail(.rejected(code))

        case .processExited, .transportReset:
            // No response at all. The request may already have been processed, so
            // this stays unknown delivery and the persisted protection remains.
            return bridge.fail(.undetermined(.connectionLost))
        }
    }

    static func failureCode(forBackendMessage message: String) -> UsageWindowStartFailureCode {
        let lowered = message.lowercased()
        if lowered.contains("login") || lowered.contains("log in")
            || lowered.contains("logged in") || lowered.contains("sign in")
            || lowered.contains("auth") || lowered.contains("unauthorized")
            || lowered.contains("401") {
            return .notAuthenticated
        }
        if lowered.contains("model") {
            return .modelRejected
        }
        return .transportError
    }
}
