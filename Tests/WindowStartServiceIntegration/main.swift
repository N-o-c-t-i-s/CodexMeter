import Combine
import Foundation

enum L10n {
    static func string(_ key: String) -> String { key }
    static func format(_ key: String, _ arguments: CVarArg...) -> String { key }
}
enum SettingsDestination { case notifications }
final class AppSettings {
    var notificationsEnabled = false
    var notificationThreshold = 20
    var historyIdentitySalt = "integration-fixture"
    var historyRetention = HistoryRetention.forever
    var settingsDestination: SettingsDestination?
    func clearSettingsError() {}
    func showSettingsError(_ message: String, destination: SettingsDestination) {}
}
final class UsageHistoryModel {
    func activateAccount(_ key: String, resetExisting: Bool, claimLegacyHistory: Bool) {}
    func deactivateAccount() {}
    func recordQuota(windows: [CodexUsageWindow], at: Date, isStale: Bool,
                     source: QuotaSampleSource, retention: HistoryRetention, accountKey: String) {}
    func recordTokenUsage(_ snapshot: TokenUsageSnapshot, retention: HistoryRetention, accountKey: String) {}
}
final class NotificationManager {
    func resetEvaluationState() {}
    func evaluate(windows: [CodexUsageWindow], threshold: Int) {}
    func requestAuthorization(completion: @escaping (Bool, String?) -> Void) { completion(false, nil) }
}
final class PushNotificationService {
    init(settings: AppSettings) {}
    func resetEvaluationState() {}
    func evaluate(windows: [CodexUsageWindow]) {}
    func sendTestBark(completion: ((Bool, String?) -> Void)?) {}
    func sendTestGotify(completion: ((Bool, String?) -> Void)?) {}
}

@main struct Integration {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }

    static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check(condition(), "asynchronous response arrived")
    }

    static func requests(_ directory: URL, method: String) -> Int {
        let text = (try? String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { line in
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["method"] as? String == method
        }.count
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for scenario in ["thread-error", "turn-error", "thread-malformed", "turn-malformed", "output-overflow", "process-exit"] {
            let directory = root.appendingPathComponent(scenario)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let executable = directory.appendingPathComponent("codex")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try scenario.write(to: directory.appendingPathComponent("scenario"), atomically: true, encoding: .utf8)
            var service: CodexUsageService? = CodexUsageService(
                settings: AppSettings(), history: UsageHistoryModel(), executableLocator: { executable }
            )
            waitUntil { service?.latestObservation != nil }

            func attempt(_ id: String) -> WindowStartTransportResult? {
                var outcome: WindowStartTransportResult?
                service!.startEphemeralWindowTurn(
                    model: "fixture", reasoningEffort: "low", prompt: "fixture", workDirectory: directory,
                    attemptID: id
                ) { outcome = $0 }
                waitUntil { outcome != nil }
                return outcome
            }

            let first = attempt("attempt-a")
            switch scenario {
            case "thread-error": check(first == .rejected(.modelRejected), "raw model error is classified without displaying backend text")
            case "turn-error": check(first == .rejected(.notAuthenticated), "raw authentication error survives localized diagnostics")
            case "thread-malformed": check(first == .rejected(.transportError), "malformed thread response releases attempt")
            default: check(first == .undetermined(.connectionLost), "\(scenario) retains unknown delivery")
            }

            if scenario == "output-overflow" || scenario == "process-exit" {
                check(requests(directory, method: "turn/interrupt") == 0, "dead transport receives no interrupt")
                let prior = requests(directory, method: "account/rateLimits/read")
                service!.refresh()
                waitUntil { requests(directory, method: "account/rateLimits/read") > prior && service?.isRefreshInFlight == false }
            }
            _ = attempt("attempt-b")
            check(requests(directory, method: "thread/start") == 2, "\(scenario) allows a real second thread/start")
            if scenario == "turn-error" || scenario == "turn-malformed" {
                waitUntil { requests(directory, method: "turn/interrupt") == 2 }
            }
            check(!(service?.errorMessage?.contains("private-backend-text") ?? false), "backend text stays out of visible errors")
            service = nil
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }
}
