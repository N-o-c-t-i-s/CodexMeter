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
    var developerPreviewEnabled = false
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

    static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 8,
                          message: String = "asynchronous response arrived") {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        check(condition(), message)
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

        let directory = root.appendingPathComponent("account-update-feedback")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try "account-update-feedback".write(to: directory.appendingPathComponent("scenario"), atomically: true, encoding: .utf8)
        let appSettings = AppSettings()
        let store = UsageWindowStartStore(directoryURL: directory.appendingPathComponent("state"))
        let key = HistoryAccountIdentity.make(
            accountType: "chatgpt", email: "fixture@example.invalid", salt: appSettings.historyIdentitySalt
        ).key
        try store.transaction { document in
            var record = document.record(for: key)
            record.settings.modelID = "fixture-a"
            record.settings.reasoningEffort = "low"
            record.settings.autoStartEnabled = true
            document.accounts[key] = record
        }
        let usage = CodexUsageService(settings: appSettings, history: UsageHistoryModel(), executableLocator: { executable })
        let coordinator = UsageWindowStartService(usage: usage, appSettings: appSettings, store: store)
        waitUntil({
            usage.latestObservation != nil && coordinator.models.count == 2
                && coordinator.settings.modelID == "fixture-a"
        }, message: "account and model selection recover after account/updated")
        check(coordinator.settings.autoStartEnabled, "account notification restores persisted switch instead of resetting the UI")
        check(coordinator.canEnableAutomation, "restored model and effort enable automation controls")
        coordinator.setAutoStartEnabled(false)
        coordinator.setModel("fixture-b")
        check(coordinator.settings.modelID == "fixture-b" && coordinator.settings.reasoningEffort == "medium",
              "model selection persists after account reconciliation")
        coordinator.setAutoStartEnabled(true)
        let record = try store.snapshot().record(for: key)
        check(record.settings.autoStartEnabled && record.settings.modelID == "fixture-b",
              "automation switch and selected model are saved to the same account")
        check(requests(directory, method: "account/read") <= 3, "account notification does not create a refresh feedback loop")
        let requestText = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        check(!requestText.contains("\"refreshToken\": true"), "account reconciliation never forces token refresh")
        check(requests(directory, method: "thread/start") == 0, "catalog recovery does not dispatch an activation")

        let logout = directory.appendingPathComponent("logged-out")
        try Data().write(to: logout)
        usage.refreshAccount()
        waitUntil({ usage.currentAccountKey == nil && coordinator.models.isEmpty && !coordinator.settings.autoStartEnabled },
                  message: "genuine logout clears models and disables automation")
        check(!coordinator.canEditSettings && !coordinator.canEnableAutomation, "no model setting can be edited without an account")
        let savedAfterLogout = try store.snapshot().record(for: key)
        check(savedAfterLogout.settings.autoStartEnabled, "logout preserves the original account's saved switch")
        try FileManager.default.removeItem(at: logout)
        coordinator.refreshModelCatalog()
        waitUntil({ coordinator.models.count == 2 && coordinator.settings.modelID == "fixture-b" && coordinator.settings.autoStartEnabled },
                  message: "reload reconnects identity and restores the same account's preferences")
        coordinator.teardown()
        print("All 7 real-service fake-server scenarios passed; no remote request sent.")
    }
}
