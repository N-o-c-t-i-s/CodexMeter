import Combine
import Foundation

/// Owns the Codex App Server process and exposes account quota as UI state.
///
/// Authentication remains inside Codex. This app only exchanges JSON-RPC
/// messages with the locally installed `codex app-server` process over stdio.
final class CodexUsageService: ObservableObject {
    @Published private(set) var windows: [CodexUsageWindow] = []
    @Published private(set) var planType: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshInFlight = false
    @Published private(set) var isStale = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var tokenUsage: TokenUsageSnapshot?
    @Published private(set) var isTokenUsageUnavailable = false
    @Published private(set) var tokenUsageErrorMessage: String?
    @Published private(set) var rateLimitResetCredits: CodexRateLimitResetCreditsSummary?
    /// Raw, display-neutral readings of the latest successful rate-limit response.
    /// The window starter decides from these; the popover keeps its own normalized view.
    @Published private(set) var latestObservation: UsageWindowObservation?
    /// The previous observation of the same account generation, used only to tell
    /// a sliding hypothetical reset from a fixed running window.
    @Published private(set) var previousObservation: UsageWindowObservation?
    /// Increments on every account boundary so late work can be discarded.
    @Published private(set) var accountGeneration = 0
    @Published private(set) var accountType: String?
    /// The local pseudonymous key of the account currently authenticated.
    @Published private(set) var currentAccountKey: String?

    private enum RequestKind: Equatable {
        case initialize
        case account
        case rateLimits
        case usage
        case models
        case threadStart
        case turnStart
    }

    private let settings: AppSettings
    private let notificationManager: NotificationManager
    let pushNotificationService: PushNotificationService
    private let history: UsageHistoryModel
    private let executableLocator: () -> URL?
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputBuffer = CodexRPCLineBuffer()
    private var standardErrorBuffer = Data()
    private let standardErrorBufferLock = NSLock()
    private let maximumStandardErrorBytes = 8 * 1_024
    private var nextRequestID = 1
    // Request IDs let responses arrive independently without losing their type.
    private var pendingRequests: [Int: RequestKind] = [:]
    private var refreshTimer: Timer?
    private var isPopoverVisible = false
    private var lastHistorySnapshot: [CodexUsageWindow]?
    private var lastHistoryAccountKey: String?
    private var lastHistoryRecordAt: Date?
    private var refreshTimeout: DispatchWorkItem?
    private var initializeTimeout: DispatchWorkItem?
    private var usageTimeout: DispatchWorkItem?
    private var restartWorkItem: DispatchWorkItem?
    private var didInitialize = false
    private var didAttemptAccountRecovery = false
    private var rateLimitRequestSources: [Int: QuotaSampleSource] = [:]
    private var usageRequestID: Int?
    private(set) var historyAccountKey: String?
    private var hasPendingAccountBoundary = false
    private var refreshSchedule = CodexRefreshSchedule()
    // A rate-limit response can arrive before the account metadata it belongs to.
    private var pendingObservation: PendingObservation?
    private var observationHistory = UsageWindowObservationHistory()
    private var observationWaiters: [(UsageWindowObservation?) -> Void] = []
    private var observationWaiterWatchdog: DispatchWorkItem?
    private var modelListCompletion: ((Result<[CodexModelSummary], any Error>) -> Void)?
    private var modelListPages: [CodexModelCatalogParser.Page] = []
    private var modelListPageCount = 0
    private var modelListTimeout: DispatchWorkItem?
    private var pendingWindowCompletion: ((WindowStartTransportResult) -> Void)?
    /// Owns the ephemeral turn's attempt identity, account generation, and JSON-RPC
    /// request identifiers. Extracted into Core so these paths are testable.
    private var windowTurnBridge = CodexWindowTurnBridge()

    init(
        settings: AppSettings,
        history: UsageHistoryModel,
        notificationManager: NotificationManager = NotificationManager(),
        pushNotificationService: PushNotificationService? = nil,
        executableLocator: @escaping () -> URL? = {
            CodexExecutableLocator.locate(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
    ) {
        self.settings = settings
        self.history = history
        self.executableLocator = executableLocator
        self.notificationManager = notificationManager
        self.pushNotificationService = pushNotificationService ?? PushNotificationService(settings: settings)

        // Defer startup until StateObject construction has completed on the main run loop.
        DispatchQueue.main.async { [weak self] in
            self?.installRefreshTimer()
            self?.start()
        }
    }

    var mostConstrainedRemainingPercent: Int? {
        mostConstrainedWindow?.remainingPercent
    }

    var mostConstrainedWindow: CodexUsageWindow? {
        // The menu bar should always represent the window closest to exhaustion.
        windows.min { $0.remainingPercent < $1.remainingPercent }
    }

    var menuBarTitle: String {
        guard let remaining = mostConstrainedRemainingPercent else {
            return isLoading ? "…" : "--"
        }
        return "\(remaining)%"
    }

    var accountDescription: String {
        guard let planType else { return L10n.string("account.checking") }
        return L10n.format("account.chatgpt_format", planType.capitalized)
    }

    func start() {
        guard process == nil else { return }

        if windows.isEmpty {
            isLoading = true
        } else {
            isStale = true
        }

        guard let codexURL = locateCodexExecutable() else {
            markFailure(L10n.string("error.codex_not_found"))
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = codexURL
        process.environment = CodexProcessEnvironment.make(
            baseEnvironment: ProcessInfo.processInfo.environment,
            executableURL: codexURL,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        // stdio transport keeps account credentials inside the official Codex process.
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading

        outputHandle.readabilityHandler = { [weak self, weak process] handle in
            do {
                let data = try CodexProcessPipe.readAvailableData(from: handle, maximumBytes: 64 * 1_024)
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                // Backpressure bounds queued output too. FileHandle invokes this on
                // its background queue; framing and process state stay on the main queue.
                DispatchQueue.main.sync {
                    guard let self, self.process === process else { return }
                    self.consumeOutput(data)
                }
            } catch {
                handle.readabilityHandler = nil
                DispatchQueue.main.sync {
                    guard let self, self.process === process else { return }
                    self.stopAppServerAfterFailure(L10n.string("error.communication"))
                }
            }
        }

        resetStandardErrorBuffer()
        errorHandle.readabilityHandler = { [weak self] handle in
            guard let data = try? CodexProcessPipe.readAvailableData(from: handle, maximumBytes: 8 * 1_024),
                  !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            // App Server may emit harmless diagnostics to stderr. Protocol errors
            // are returned as JSON-RPC messages on stdout. Always drain stderr so
            // unread bytes cannot keep the file descriptor continuously readable.
            self?.consumeStandardError(data)
        }

        process.terminationHandler = { [weak self, weak process] terminatedProcess in
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil

            let terminationStatus = terminatedProcess.terminationStatus
            let terminationReason = terminatedProcess.terminationReason

            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                let standardError = self.drainStandardErrorBuffer()
                self.clearAppServerResources()
                self.didInitialize = false
                self.perform(CodexWindowTurnFailureRouter.action(
                    for: .processExited,
                    bridge: &self.windowTurnBridge
                ))
                self.finishModelList(.failure(UsageWindowStartBridgeError.unavailable))
                self.pendingRequests.removeAll()
                self.rateLimitRequestSources.removeAll()
                self.cancelRefreshTimeout()
                self.cancelUsageTimeout()
                self.usageRequestID = nil
                self.markFailure(self.appServerStoppedMessage(
                    standardError: standardError,
                    terminationStatus: terminationStatus,
                    terminationReason: terminationReason
                ))
            }
        }

        // Writing after the child exits must fail with EPIPE instead of raising
        // SIGPIPE, whose default action terminates the whole menu bar app.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        do {
            try process.run()
            self.process = process
            inputHandle = inputPipe.fileHandleForWriting
            self.outputHandle = outputHandle
            self.errorHandle = errorHandle

            guard let requestID = sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex_meter",
                        "title": "Codex Meter",
                        "version": appVersion
                    ]
                ],
                kind: .initialize
            ) else {
                // send() already reported the failure; drop the unusable child so
                // the next refresh starts a new one.
                clearAppServerResources(terminate: true)
                return
            }
            scheduleInitializeTimeout(for: requestID)
        } catch {
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            clearAppServerResources()
            markFailure(L10n.string("error.app_server_start_failed"))
        }
    }

    func refresh() {
        refresh(forceTokenRefresh: false, source: .refresh)
    }

    private func refresh(forceTokenRefresh: Bool, source: QuotaSampleSource) {
        if process == nil {
            start()
            return
        }

        // App Server requires initialization first; skip overlapping refreshes.
        guard didInitialize, !isRefreshInFlight else { return }

        isRefreshInFlight = true
        if windows.isEmpty {
            isLoading = true
        }
        errorMessage = nil

        let now = Date()
        if forceTokenRefresh || refreshSchedule.accountDue(at: now) {
            // Drop unanswered account requests before retrying; ignore their late replies.
            pendingRequests = pendingRequests.filter { $0.value != .account }
            refreshSchedule.lastAccountAttempt = now
            _ = sendRequest(
                method: "account/read",
                params: ["refreshToken": forceTokenRefresh],
                kind: .account
            )
        } else if !pendingRequests.values.contains(.account) {
            requestTokenUsageIfNeeded()
        }

        guard let requestID = sendRequest(
            method: "account/rateLimits/read",
            params: [:],
            kind: .rateLimits
        ) else {
            if restartAppServerAfterAccountFailure() {
                return
            }
            markFailure(L10n.string("error.communication"))
            return
        }

        rateLimitRequestSources[requestID] = source
        scheduleRefreshTimeout(for: requestID)
    }

    func refreshIfNeeded(maxAge: TimeInterval = 10) {
        guard refreshSchedule.mayPoll(at: Date()) else { return }
        guard let lastUpdated else {
            refresh()
            return
        }

        if Date().timeIntervalSince(lastUpdated) >= maxAge {
            refresh()
        }
    }

    func setPopoverVisible(_ visible: Bool) {
        guard isPopoverVisible != visible else { return }
        isPopoverVisible = visible
        installRefreshTimer()
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            settings.notificationsEnabled = false
            if settings.settingsDestination == .notifications {
                settings.clearSettingsError()
            }
            return
        }

        notificationManager.requestAuthorization { [weak self] granted, error in
            guard let self else { return }
            self.settings.notificationsEnabled = granted
            if granted {
                self.settings.clearSettingsError()
                self.notificationManager.evaluate(
                    windows: self.windows,
                    threshold: self.settings.notificationThreshold
                )
            } else {
                let message = error ?? L10n.string("settings.notification_denied")
                self.settings.showSettingsError(message, destination: .notifications)
            }
        }
    }

    func sendTestBarkPush(completion: ((Bool, String?) -> Void)? = nil) {
        pushNotificationService.sendTestBark(completion: completion)
    }

    func sendTestGotifyPush(completion: ((Bool, String?) -> Void)? = nil) {
        pushNotificationService.sendTestGotify(completion: completion)
    }

    private func installRefreshTimer() {
        refreshTimer?.invalidate()
        // This refreshes server data. Countdown-only UI updates use TimelineView.
        let interval = isPopoverVisible
            ? CodexRefreshSchedule.foregroundQuotaInterval
            : CodexRefreshSchedule.backgroundQuotaInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.refreshSchedule.mayPoll(at: Date()),
                      self.restartWorkItem == nil else { return }
                self.refresh()
            }
        }
        timer.tolerance = isPopoverVisible ? 1 : 5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func clearAppServerResources(terminate: Bool = false) {
        // Every teardown path passes through here, including restarts.
        cancelInitializeTimeout()
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil

        let runningProcess = process
        runningProcess?.terminationHandler = nil

        inputHandle?.closeFile()
        outputHandle?.closeFile()
        errorHandle?.closeFile()

        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        outputBuffer = CodexRPCLineBuffer()

        if terminate, runningProcess?.isRunning == true {
            runningProcess?.terminate()
        }
    }

    @discardableResult
    private func sendRequest(
        method: String,
        params: Any,
        kind: RequestKind
    ) -> Int? {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[id] = kind

        guard send(["method": method, "id": id, "params": params]) else {
            pendingRequests.removeValue(forKey: id)
            return nil
        }
        return id
    }

    @discardableResult
    private func send(_ object: [String: Any]) -> Bool {
        guard let inputHandle else { return false }

        do {
            var data = try JSONSerialization.data(withJSONObject: object)
            // App Server's stdio protocol uses one JSON object per line.
            data.append(0x0A)
            try inputHandle.write(contentsOf: data)
            return true
        } catch {
            markFailure(L10n.string("error.communication"))
            return false
        }
    }

    private func consumeOutput(_ data: Data) {
        let sourceProcess = process
        do {
            for line in try outputBuffer.append(data) {
                // A response may restart the child; discard its remaining messages.
                guard process === sourceProcess else { return }
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                handleMessage(object)
            }
        } catch {
            stopAppServerAfterFailure(L10n.string("error.app_server_output_too_large"))
        }
    }

    private func stopAppServerAfterFailure(_ message: String) {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        cancelRefreshTimeout()
        cancelUsageTimeout()
        pendingRequests.removeAll()
        rateLimitRequestSources.removeAll()
        usageRequestID = nil
        didInitialize = false
        clearAppServerResources(terminate: true)
        perform(CodexWindowTurnFailureRouter.action(
            for: .transportReset,
            bridge: &windowTurnBridge
        ))
        finishModelList(.failure(UsageWindowStartBridgeError.unavailable))
        resetStandardErrorBuffer()
        markFailure(message)
    }

    private func consumeStandardError(_ data: Data) {
        guard !data.isEmpty else { return }

        standardErrorBufferLock.lock()
        defer { standardErrorBufferLock.unlock() }

        if data.count >= maximumStandardErrorBytes {
            standardErrorBuffer = Data(data.suffix(maximumStandardErrorBytes))
            return
        }

        standardErrorBuffer.append(data)
        if standardErrorBuffer.count > maximumStandardErrorBytes {
            standardErrorBuffer.removeFirst(
                standardErrorBuffer.count - maximumStandardErrorBytes
            )
        }
    }

    private func resetStandardErrorBuffer() {
        standardErrorBufferLock.lock()
        standardErrorBuffer.removeAll(keepingCapacity: true)
        standardErrorBufferLock.unlock()
    }

    private func drainStandardErrorBuffer() -> Data {
        standardErrorBufferLock.lock()
        defer { standardErrorBufferLock.unlock() }

        let data = standardErrorBuffer
        standardErrorBuffer.removeAll(keepingCapacity: true)
        return data
    }

    private func appServerStoppedMessage(
        standardError: Data,
        terminationStatus: Int32,
        terminationReason: Process.TerminationReason
    ) -> String {
        if CodexProcessDiagnostic.isNodeRuntimeMissing(in: standardError) {
            return L10n.string("error.node_runtime_not_found")
        }
        if terminationReason == .exit, terminationStatus != 0 {
            return L10n.format(
                "error.app_server_stopped_status_format",
                Int(terminationStatus)
            )
        }
        return L10n.string("error.app_server_stopped")
    }

    private func handleMessage(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            switch method {
            case "account/updated":
                handleAccountUpdated()
            case "account/rateLimits/updated":
                // A server-side quota change should bypass the next scheduled refresh.
                refresh(forceTokenRefresh: false, source: .notification)
            case "turn/completed":
                handleTurnCompleted(message)
            default:
                break
            }
            return
        }

        guard let id = message["id"] as? Int else { return }
        guard let kind = pendingRequests.removeValue(forKey: id) else {
            // Ignore late responses from an App Server that was replaced during recovery.
            return
        }
        let rateLimitSource = rateLimitRequestSources.removeValue(forKey: id) ?? .refresh

        if kind == .usage {
            finishUsageRequest(id: id)
        }

        if let error = message["error"] as? [String: Any] {
            let text = L10n.string(CodexProcessDiagnostic.rpcErrorLocalizationKey(error))
            if (kind == .account || kind == .rateLimits),
               restartAppServerAfterAccountFailure() {
                return
            }

            if kind == .initialize {
                // refresh() only restarts a missing child, so an uninitialized
                // child must be stopped rather than left running.
                stopAppServerAfterFailure(text)
            } else if kind == .rateLimits {
                cancelRefreshTimeout()
                markFailure(text)
            } else if kind == .usage {
                isTokenUsageUnavailable = true
                tokenUsageErrorMessage = text
            } else if kind == .account {
                errorMessage = text
            } else if kind == .models {
                // A catalog failure must never change the quota presentation.
                finishModelList(.failure(UsageWindowStartBridgeError.unavailable))
            } else if kind == .threadStart {
                perform(CodexWindowTurnFailureRouter.action(
                    for: .threadStart,
                    backendMessage: error["message"] as? String,
                    bridge: &windowTurnBridge
                ))
            } else if kind == .turnStart {
                perform(CodexWindowTurnFailureRouter.action(
                    for: .turnStart,
                    backendMessage: error["message"] as? String,
                    bridge: &windowTurnBridge
                ))
            } else {
                markFailure(text)
            }
            return
        }

        guard let result = message["result"] as? [String: Any] else {
            // The request has already left pendingRequests, so its timeout can no
            // longer clean up; release the state each kind would otherwise hold.
            switch kind {
            case .initialize:
                stopAppServerAfterFailure(L10n.string("error.communication"))
            case .rateLimits:
                cancelRefreshTimeout()
                markFailure(L10n.string("error.communication"))
            case .usage:
                isTokenUsageUnavailable = true
                tokenUsageErrorMessage = L10n.string("error.communication")
            case .account:
                break
            case .models:
                finishModelList(.failure(UsageWindowStartBridgeError.unavailable))
            case .threadStart:
                perform(windowTurnBridge.fail(.rejected(.transportError)))
            case .turnStart:
                perform(windowTurnBridge.fail(.undetermined(.connectionLost)))
            }
            return
        }

        switch kind {
        case .initialize:
            cancelInitializeTimeout()
            didInitialize = true
            refreshSchedule.lastAccountAttempt = nil
            _ = send(["method": "initialized", "params": [:]])
            refresh()
        case .account:
            parseAccount(result)
        case .rateLimits:
            cancelRefreshTimeout()
            parseRateLimits(result, source: rateLimitSource)
        case .usage:
            parseTokenUsage(result)
        case .models:
            handleModelListResult(result)
        case .threadStart:
            handleThreadStartResult(result, requestID: id)
        case .turnStart:
            handleTurnStartResult(result, requestID: id)
        }
    }

    private func handleAccountUpdated() {
        cancelRefreshTimeout()
        pendingRequests = pendingRequests.filter { $0.value == .initialize }
        rateLimitRequestSources.removeAll()
        cancelUsageTimeout()
        usageRequestID = nil
        isRefreshInFlight = false

        // Never keep the previous account's quota visible after an explicit auth change.
        windows = []
        planType = nil
        lastUpdated = nil
        isLoading = true
        isStale = false
        errorMessage = nil
        tokenUsage = nil
        isTokenUsageUnavailable = false
        tokenUsageErrorMessage = nil
        rateLimitResetCredits = nil
        historyAccountKey = nil
        lastHistorySnapshot = nil
        lastHistoryAccountKey = nil
        lastHistoryRecordAt = nil
        hasPendingAccountBoundary = true
        refreshSchedule = CodexRefreshSchedule()
        history.deactivateAccount()
        notificationManager.resetEvaluationState()
        pushNotificationService.resetEvaluationState()

        // An account boundary invalidates every pending window-start decision,
        // including a thread that has not advanced to a turn yet.
        invalidateWindowTurnForAccountBoundary()
        accountType = nil
        currentAccountKey = nil
        accountGeneration += 1
        latestObservation = nil
        previousObservation = nil
        observationHistory = UsageWindowObservationHistory()
        pendingObservation = nil
        resolveObservationWaiters(with: nil)

        // App Server has already applied the auth change. Force its managed ChatGPT
        // token refresh before asking for the new account's quota.
        refresh(forceTokenRefresh: true, source: .notification)
    }

    private func parseAccount(_ result: [String: Any]) {
        let account = result["account"] as? [String: Any]
        let type = account?["type"] as? String
        let plan = account?["planType"] as? String

        if type == "chatgpt" {
            planType = plan ?? "unknown"
        } else if type == "apiKey" {
            planType = "API Key"
        } else if type == "amazonBedrock" {
            planType = "Bedrock"
        } else if account == nil {
            errorMessage = L10n.string("error.not_logged_in")
            historyAccountKey = nil
            hasPendingAccountBoundary = false
            accountType = nil
            currentAccountKey = nil
            accountGeneration += 1
            invalidateWindowTurnForAccountBoundary()
            latestObservation = nil
            previousObservation = nil
            observationHistory = UsageWindowObservationHistory()
            pendingObservation = nil
            history.deactivateAccount()
            resolveObservationWaiters(with: nil)
            return
        }

        guard let type else { return }

        let identity = HistoryAccountIdentity.make(
            accountType: type,
            email: account?["email"] as? String,
            salt: settings.historyIdentitySalt
        )
        // Distinguishes the first identity of this connection from a real switch.
        let previousAccountKey = historyAccountKey
        let accountChanged = previousAccountKey != identity.key || hasPendingAccountBoundary
        let shouldResetAnonymousHistory = hasPendingAccountBoundary && !identity.isStable
        historyAccountKey = identity.key
        hasPendingAccountBoundary = false
        accountType = type
        currentAccountKey = identity.key

        if accountChanged {
            // Every generation-scoped decision and in-flight waiter belongs to
            // the account that just ended. A rate-limit read that arrived before
            // this metadata is kept only when there was no previous identity, so
            // the first observation is not discarded on every launch.
            accountGeneration += 1
            // `account/read` can notice an identity change without an
            // `account/updated` notification, so the same boundary cleanup runs
            // here rather than relying on one notification order.
            invalidateWindowTurnForAccountBoundary()
            latestObservation = nil
            previousObservation = nil
            observationHistory = UsageWindowObservationHistory()
            if previousAccountKey != nil {
                pendingObservation = nil
            }
            resolveObservationWaiters(with: nil)
        }

        if accountChanged {
            tokenUsage = nil
            refreshSchedule.lastUsageAttempt = nil
            history.activateAccount(
                identity.key,
                resetExisting: shouldResetAnonymousHistory,
                claimLegacyHistory: identity.isStable
            )

            // A rate-limit response can arrive before account/read. Save the live
            // snapshot once its owning account is known instead of dropping it.
            if let lastUpdated, !windows.isEmpty {
                history.recordQuota(
                    windows: windows,
                    at: lastUpdated,
                    isStale: isStale,
                    source: .refresh,
                    retention: settings.historyRetention,
                    accountKey: identity.key
                )
            }
        }

        // A rate-limit response can arrive before this metadata; publish it only
        // now that the owning account is known.
        flushPendingObservation()

        // Token usage is requested only after the account identity is known so a
        // late response can never be written into another account's partition.
        requestTokenUsageIfNeeded()
    }

    private func parseRateLimits(_ result: [String: Any], source: QuotaSampleSource) {
        let observedAt = Date()
        let readings = UsageWindowObservationParser.readings(
            fromRateLimitsResult: result,
            observedAt: observedAt
        )
        let authorization = UsageWindowObservationParser.authorization(
            fromRateLimitsResult: result
        )
        var parsed: [CodexUsageWindow] = []

        // Support both current multi-bucket responses and the legacy single snapshot.
        if let buckets = result["rateLimitsByLimitId"] as? [String: Any],
           !buckets.isEmpty {
            for (bucketID, value) in buckets {
                guard let snapshot = value as? [String: Any] else { continue }
                parsed.append(contentsOf: parseSnapshot(snapshot, fallbackID: bucketID))
            }
        } else if let snapshot = result["rateLimits"] as? [String: Any] {
            parsed = parseSnapshot(snapshot, fallbackID: "codex")
        }

        // Shorter windows appear first in the details popover.
        parsed.sort {
            ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max)
        }

        guard !parsed.isEmpty else {
            if restartAppServerAfterAccountFailure() {
                return
            }
            markFailure(L10n.string("error.no_windows"))
            return
        }

        let updatedAt = Date()
        if windows != parsed { windows = parsed }
        let resetCredits = CodexRateLimitResetCreditsSummary.decode(
            fromRateLimitsResult: result
        )
        if rateLimitResetCredits != resetCredits {
            rateLimitResetCredits = resetCredits
        }
        isLoading = false
        isRefreshInFlight = false
        isStale = false
        lastUpdated = updatedAt
        errorMessage = nil
        didAttemptAccountRecovery = false
        refreshSchedule.succeeded()
        publishObservation(
            readings: readings,
            authorization: authorization,
            observedAt: updatedAt
        )

        if let historyAccountKey,
           shouldRecordQuotaHistory(parsed, accountKey: historyAccountKey, at: updatedAt) {
            lastHistoryAccountKey = historyAccountKey
            lastHistorySnapshot = parsed
            lastHistoryRecordAt = updatedAt
            history.recordQuota(
                windows: parsed,
                at: updatedAt,
                isStale: false,
                source: source,
                retention: settings.historyRetention,
                accountKey: historyAccountKey
            )
        }

        if settings.notificationsEnabled {
            notificationManager.evaluate(
                windows: parsed,
                threshold: settings.notificationThreshold
            )
        }
        pushNotificationService.evaluate(windows: parsed)
    }

    private func shouldRecordQuotaHistory(
        _ current: [CodexUsageWindow],
        accountKey: String,
        at date: Date
    ) -> Bool {
        guard lastHistoryAccountKey == accountKey,
              let previous = lastHistorySnapshot,
              let lastHistoryRecordAt else { return true }
        if date.timeIntervalSince(lastHistoryRecordAt) >= 15 * 60 { return true }
        guard previous.count == current.count else { return true }
        let previousByID = Dictionary(previous.map { ($0.historyID, $0) },
                                      uniquingKeysWith: { first, _ in first })
        return current.contains { window in
            guard let prior = previousByID[window.historyID] else { return true }
            return prior.remainingPercent != window.remainingPercent
                || prior.windowDurationMins != window.windowDurationMins
                || prior.name != window.name
                || QuotaCycleDetection.resetMeaningfullyChanged(
                    previousRemaining: prior.remainingPercent,
                    previousReset: prior.resetsAt,
                    currentRemaining: window.remainingPercent,
                    currentReset: window.resetsAt
                )
        }
    }

    private func requestTokenUsageIfNeeded() {
        guard usageRequestID == nil, historyAccountKey != nil,
              refreshSchedule.usageDue(at: Date()) else { return }
        refreshSchedule.lastUsageAttempt = Date()
        guard let id = sendRequest(
            method: "account/usage/read",
            params: NSNull(),
            kind: .usage
        ) else {
            return
        }
        usageRequestID = id
        scheduleUsageTimeout(for: id)
    }

    private func parseTokenUsage(_ result: [String: Any]) {
        guard let summaryObject = result["summary"] as? [String: Any] else {
            isTokenUsageUnavailable = true
            tokenUsageErrorMessage = L10n.string("history.tokens.unavailable")
            return
        }

        let buckets: [TokenUsageDailyBucket]?
        if let rawBuckets = result["dailyUsageBuckets"] as? [[String: Any]] {
            buckets = rawBuckets.compactMap { object in
                guard let startDate = object["startDate"] as? String,
                      let tokens = int64(object["tokens"]) else {
                    return nil
                }
                return TokenUsageDailyBucket(startDate: startDate, tokens: tokens)
            }
        } else {
            buckets = nil
        }

        let snapshot = TokenUsageSnapshot(
            dailyBuckets: buckets,
            summary: TokenUsageSummary(
                lifetimeTokens: int64(summaryObject["lifetimeTokens"]),
                peakDailyTokens: int64(summaryObject["peakDailyTokens"]),
                currentStreakDays: int64(summaryObject["currentStreakDays"]),
                longestStreakDays: int64(summaryObject["longestStreakDays"]),
                longestRunningTurnSeconds: int64(summaryObject["longestRunningTurnSec"])
            ),
            fetchedAt: Date()
        )
        isTokenUsageUnavailable = false
        tokenUsageErrorMessage = nil
        // fetchedAt changes on every response; it is not a change in usage data.
        guard tokenUsage?.dailyBuckets != snapshot.dailyBuckets
                || tokenUsage?.summary != snapshot.summary else { return }
        tokenUsage = snapshot
        if let historyAccountKey {
            history.recordTokenUsage(
                snapshot,
                retention: settings.historyRetention,
                accountKey: historyAccountKey
            )
        }
    }

    private func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        return value as? Int64
    }

    private func parseSnapshot(
        _ snapshot: [String: Any],
        fallbackID: String
    ) -> [CodexUsageWindow] {
        let limitID = snapshot["limitId"] as? String ?? fallbackID
        let rawName = snapshot["limitName"] as? String
        let bucketName = friendlyBucketName(rawName ?? limitID)
        var result: [CodexUsageWindow] = []

        if let primary = snapshot["primary"] as? [String: Any],
           let window = makeWindow(primary, id: "\(limitID)-primary", bucketName: bucketName) {
            result.append(window)
        }

        if let secondary = snapshot["secondary"] as? [String: Any],
           let window = makeWindow(secondary, id: "\(limitID)-secondary", bucketName: bucketName) {
            result.append(window)
        }

        return result
    }

    private func makeWindow(
        _ object: [String: Any],
        id: String,
        bucketName: String
    ) -> CodexUsageWindow? {
        guard let usedPercent = object["usedPercent"] as? Int else { return nil }

        let duration = object["windowDurationMins"] as? Int
        let resetTimestamp = (object["resetsAt"] as? NSNumber)?.doubleValue
        let durationName = friendlyDuration(duration)
        let displayName = bucketName == "Codex"
            ? durationName
            : L10n.format("duration.bucket_format", bucketName, durationName)

        return CodexUsageWindow(
            id: id,
            name: displayName,
            usedPercent: usedPercent,
            windowDurationMins: duration,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func friendlyDuration(_ minutes: Int?) -> String {
        guard let minutes else { return L10n.string("duration.quota") }
        switch minutes {
        case 300:
            return L10n.string("duration.five_hours")
        case 10_080:
            return L10n.string("duration.weekly")
        case let value where value.isMultiple(of: 1_440):
            return L10n.format("duration.days_format", value / 1_440)
        case let value where value.isMultiple(of: 60):
            return L10n.format("duration.hours_format", value / 60)
        default:
            return L10n.format("duration.minutes_format", minutes)
        }
    }

    private func friendlyBucketName(_ value: String) -> String {
        switch value.lowercased() {
        case "codex": return "Codex"
        default:
            return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func scheduleRefreshTimeout(for requestID: Int) {
        cancelRefreshTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingRequests[requestID] == .rateLimits else {
                return
            }
            self.pendingRequests.removeValue(forKey: requestID)
            self.rateLimitRequestSources.removeValue(forKey: requestID)
            if self.restartAppServerAfterAccountFailure() {
                return
            }
            self.markFailure(L10n.string("error.request_timeout"))
        }
        refreshTimeout = workItem
        // Avoid leaving the UI in a permanent loading state if App Server stalls.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func cancelRefreshTimeout() {
        refreshTimeout?.cancel()
        refreshTimeout = nil
    }

    private func scheduleInitializeTimeout(for requestID: Int) {
        cancelInitializeTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingRequests[requestID] == .initialize else {
                return
            }
            self.stopAppServerAfterFailure(L10n.string("error.request_timeout"))
        }
        initializeTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func cancelInitializeTimeout() {
        initializeTimeout?.cancel()
        initializeTimeout = nil
    }

    private func scheduleUsageTimeout(for requestID: Int) {
        cancelUsageTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.usageRequestID == requestID else { return }
            self.pendingRequests.removeValue(forKey: requestID)
            self.usageRequestID = nil
            self.isTokenUsageUnavailable = true
            self.tokenUsageErrorMessage = L10n.string("error.request_timeout")
        }
        usageTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func finishUsageRequest(id: Int) {
        guard usageRequestID == id else { return }
        usageRequestID = nil
        cancelUsageTimeout()
    }

    private func cancelUsageTimeout() {
        usageTimeout?.cancel()
        usageTimeout = nil
    }

    @discardableResult
    private func restartAppServerAfterAccountFailure() -> Bool {
        guard !didAttemptAccountRecovery, restartWorkItem == nil else {
            return false
        }

        didAttemptAccountRecovery = true
        cancelRefreshTimeout()
        perform(CodexWindowTurnFailureRouter.action(
            for: .transportReset,
            bridge: &windowTurnBridge
        ))
        finishModelList(.failure(UsageWindowStartBridgeError.unavailable))
        pendingRequests.removeAll()
        rateLimitRequestSources.removeAll()
        cancelUsageTimeout()
        usageRequestID = nil
        didInitialize = false
        isRefreshInFlight = false

        if windows.isEmpty {
            isLoading = true
        } else {
            isStale = true
        }
        errorMessage = nil

        clearAppServerResources(terminate: true)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.start()
        }
        restartWorkItem = workItem

        // Give Codex a brief moment to finish replacing its persisted login state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        return true
    }

    private func markFailure(_ message: String) {
        refreshSchedule.failed(at: Date())
        isLoading = false
        isRefreshInFlight = false
        // Preserve the last successful snapshot and explicitly mark it as stale.
        isStale = !windows.isEmpty
        errorMessage = message
        // A failed read must never leave a window-start caller waiting forever.
        resolveObservationWaiters(with: nil)
    }


    // MARK: - Usage window starter bridge

    /// One successful response held until the account metadata it belongs to has
    /// arrived, so a rate-limit result is never attributed to the wrong account.
    private struct PendingObservation {
        let readings: [UsageWindowReading]
        let authorization: UsageWindowAuthorization
        let observedAt: Date
    }

    /// Requests a read that actually reaches the App Server and resolves with the
    /// observation it publishes.
    ///
    /// An in-flight refresh already produces a fresh answer, so waiters attach to
    /// it instead of treating the skipped duplicate request as a completed one.
    func requestFreshObservation(completion: @escaping (UsageWindowObservation?) -> Void) {
        observationWaiters.append(completion)
        // Startup, a stall, or a crashed App Server must never leave a caller
        // waiting forever, so every waiter has a bounded lifetime.
        scheduleObservationWaiterWatchdog()

        if process == nil {
            start()
        }
        // During initialization the response chain ends in a refresh, which
        // resolves these waiters; the watchdog covers a server that never answers.
        guard didInitialize else { return }
        if isRefreshInFlight { return }

        refresh()
        if !isRefreshInFlight {
            resolveObservationWaiters(with: nil)
        }
    }

    private func scheduleObservationWaiterWatchdog() {
        observationWaiterWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.resolveObservationWaiters(with: nil)
        }
        observationWaiterWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: workItem)
    }

    private func cancelObservationWaiterWatchdog() {
        observationWaiterWatchdog?.cancel()
        observationWaiterWatchdog = nil
    }

    /// Reads the model catalog, following `nextCursor`. A failure here only
    /// affects the window-start settings, never the quota presentation.
    func requestModels(completion: @escaping (Result<[CodexModelSummary], any Error>) -> Void) {
        finishModelList(.failure(UsageWindowStartBridgeError.unavailable))

        guard process != nil, didInitialize else {
            completion(.failure(UsageWindowStartBridgeError.unavailable))
            return
        }

        modelListCompletion = completion
        modelListPages = []
        modelListPageCount = 0
        sendModelListPage(cursor: nil)
    }

    private func sendModelListPage(cursor: String?) {
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }

        guard sendRequest(method: "model/list", params: params, kind: .models) != nil else {
            finishModelList(.failure(UsageWindowStartBridgeError.unavailable))
            return
        }
        scheduleModelListTimeout()
    }

    private func handleModelListResult(_ result: [String: Any]) {
        cancelModelListTimeout()

        let page = CodexModelCatalogParser.page(fromResult: result)
        modelListPages.append(page)
        modelListPageCount += 1

        if let cursor = page.nextCursor,
           modelListPageCount < CodexModelCatalogParser.maximumPages {
            sendModelListPage(cursor: cursor)
            return
        }
        finishModelList(.success(CodexModelCatalogParser.merged(modelListPages)))
    }

    private func scheduleModelListTimeout() {
        cancelModelListTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finishModelList(.failure(UsageWindowStartBridgeError.timedOut))
        }
        modelListTimeout = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
    }

    private func cancelModelListTimeout() {
        modelListTimeout?.cancel()
        modelListTimeout = nil
    }

    private func finishModelList(_ result: Result<[CodexModelSummary], any Error>) {
        cancelModelListTimeout()
        guard let completion = modelListCompletion else { return }
        modelListCompletion = nil
        modelListPages = []
        modelListPageCount = 0
        completion(result)
    }

    private func publishObservation(
        readings: [UsageWindowReading],
        authorization: UsageWindowAuthorization,
        observedAt: Date
    ) {
        guard let accountKey = historyAccountKey, let accountType else {
            pendingObservation = PendingObservation(
                readings: readings,
                authorization: authorization,
                observedAt: observedAt
            )
            return
        }

        let observation = UsageWindowObservation(
            observedAt: observedAt,
            accountGeneration: accountGeneration,
            accountKey: accountKey,
            accountType: accountType,
            authorization: authorization,
            readings: readings
        )

        previousObservation = observationHistory.append(observation)
        latestObservation = observation
        pendingObservation = nil
        resolveObservationWaiters(with: observation)
    }

    private func flushPendingObservation() {
        guard let pending = pendingObservation,
              historyAccountKey != nil,
              accountType != nil else {
            return
        }
        pendingObservation = nil
        publishObservation(
            readings: pending.readings,
            authorization: pending.authorization,
            observedAt: pending.observedAt
        )
    }

    private func resolveObservationWaiters(with observation: UsageWindowObservation?) {
        guard !observationWaiters.isEmpty else { return }
        cancelObservationWaiterWatchdog()
        let waiters = observationWaiters
        observationWaiters.removeAll()
        waiters.forEach { $0(observation) }
    }

    // MARK: - Ephemeral turn transport

    /// Runs one minimal turn on the already authenticated App Server connection.
    ///
    /// Using this connection rather than a separate `codex exec` child is what
    /// makes the send identity provable: the turn reaches the same process, the
    /// same `CODEX_HOME`, and the same provider configuration that produced the
    /// quota observation. No token is read, copied, or logged.
    ///
    /// `Core/CodexWindowTurnBridge.swift` owns every decision here; this type only
    /// executes the returned action. It is main-thread only: start, cancel, reply
    /// handling, and the runner's timeout all run on the main queue, so the
    /// pending-request table and the bridge need no locking of their own.
    func startEphemeralWindowTurn(
        model: String,
        reasoningEffort: String,
        prompt: String,
        workDirectory: URL,
        attemptID: String,
        completion: @escaping (WindowStartTransportResult) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard process != nil, didInitialize else {
            completion(.rejected(.notAuthenticated))
            return
        }

        // One turn at a time. Overwriting the slot would orphan the previous
        // attempt's completion until its runner timeout fired, and a bridge that
        // is still occupied must never be handed another request, so refuse
        // before touching either.
        guard pendingWindowCompletion == nil, windowTurnBridge.isIdle else {
            completion(.rejected(.concurrentRequest))
            return
        }
        pendingWindowCompletion = completion

        let payload = WindowStartTurnPayload(
            attemptID: attemptID,
            generation: accountGeneration,
            model: model,
            effort: reasoningEffort,
            prompt: prompt,
            workDirectory: workDirectory
        )
        perform(windowTurnBridge.begin(payload))
    }

    func cancelEphemeralWindowTurn(attemptID: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        perform(windowTurnBridge.cancel(attemptID: attemptID))
    }

    /// Abandons the in-flight turn because its account generation ended.
    private func invalidateWindowTurnForAccountBoundary() {
        perform(windowTurnBridge.accountBoundary())
    }

    /// Executes one bridge action. Every path here runs on the main queue.
    private func perform(_ action: CodexWindowTurnBridge.Action) {
        switch action {
        case let .sendThread(payload):
            try? FileManager.default.createDirectory(
                at: payload.workDirectory,
                withIntermediateDirectories: true
            )
            let params: [String: Any] = [
                "ephemeral": true,
                "model": payload.model,
                "cwd": payload.workDirectory.path,
                // Never prompt, and never let the turn touch the user's files.
                "approvalPolicy": "never",
                "sandbox": "read-only"
            ]
            guard let requestID = sendRequest(
                method: "thread/start",
                params: params,
                kind: .threadStart
            ) else {
                perform(windowTurnBridge.fail(.rejected(.transportError)))
                return
            }
            windowTurnBridge.threadRequestRegistered(id: requestID)

        case let .sendTurn(_, threadID, model, effort, prompt):
            let params: [String: Any] = [
                "threadId": threadID,
                "model": model,
                "effort": effort,
                "input": [["type": "text", "text": prompt]]
            ]
            guard let requestID = sendRequest(
                method: "turn/start",
                params: params,
                kind: .turnStart
            ) else {
                perform(windowTurnBridge.fail(.undetermined(.connectionLost)))
                return
            }
            windowTurnBridge.turnRequestRegistered(id: requestID)

        case let .abandon(requestIDs, threadID, turnID, result):
            // Forgetting the identifiers is what drops a late reply before it can
            // be attributed to the attempt that replaced this one.
            for requestID in requestIDs {
                pendingRequests.removeValue(forKey: requestID)
            }
            // A dead App Server cannot acknowledge an interrupt, and writing into
            // a closed pipe must not be treated as part of the cleanup.
            if let threadID, transportCanReceiveRequests {
                var params: [String: Any] = ["threadId": threadID]
                if let turnID {
                    params["turnId"] = turnID
                }
                sendUntrackedRequest(method: "turn/interrupt", params: params)
            }
            finishWindowTurn(result)

        case let .finish(result):
            finishWindowTurn(result)

        case .drop:
            break
        }
    }

    private func handleThreadStartResult(_ result: [String: Any], requestID: Int) {
        guard let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            perform(windowTurnBridge.fail(.rejected(.transportError)))
            return
        }
        perform(windowTurnBridge.receiveThreadReply(
            requestID: requestID,
            generation: accountGeneration,
            threadID: threadID,
            modelProvider: result["modelProvider"] as? String
        ))
    }

    private func handleTurnStartResult(_ result: [String: Any], requestID: Int) {
        guard let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            return
        }
        // The turn's outcome arrives as a `turn/completed` notification.
        perform(windowTurnBridge.receiveTurnReply(
            requestID: requestID,
            generation: accountGeneration,
            turnID: turnID
        ))
    }

    private func handleTurnCompleted(_ message: [String: Any]) {
        let params = message["params"] as? [String: Any] ?? [:]
        guard let threadID = params["threadId"] as? String else { return }

        let turn = params["turn"] as? [String: Any] ?? [:]
        perform(windowTurnBridge.receiveCompletion(
            threadID: threadID,
            turnID: turn["id"] as? String,
            generation: accountGeneration,
            status: turn["status"] as? String ?? "failed",
            errorMessage: (turn["error"] as? [String: Any])?["message"] as? String
        ))
    }

    /// Delivers one terminal result. Every caller must have released the attempt
    /// through the bridge first, because a result that arrives while the bridge
    /// still owns the attempt leaves it occupied and refuses every later retry.
    private func finishWindowTurn(_ result: WindowStartTransportResult) {
        assert(
            windowTurnBridge.isIdle,
            "a turn result must be delivered after its attempt is released"
        )
        guard let completion = pendingWindowCompletion else { return }
        pendingWindowCompletion = nil
        completion(result)
    }

    private var transportCanReceiveRequests: Bool {
        process != nil && didInitialize
    }


    private func sendUntrackedRequest(method: String, params: Any) {
        // A response to an untracked id is ignored by handleMessage.
        let id = nextRequestID
        nextRequestID += 1
        _ = send(["method": method, "id": id, "params": params])
    }

    private func locateCodexExecutable() -> URL? {
        executableLocator()
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    deinit {
        refreshTimer?.invalidate()
        refreshTimeout?.cancel()
        usageTimeout?.cancel()
        restartWorkItem?.cancel()
        clearAppServerResources(terminate: true)
    }
}

/// Errors the window starter sees when it asks for data the App Server could not
/// supply in time. Localized at display time.
enum UsageWindowStartBridgeError: Error, Equatable {
    case unavailable
    case timedOut
}
