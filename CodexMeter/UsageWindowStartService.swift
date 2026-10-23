import AppKit
import Combine
import Foundation

/// Serial coordinator for usage-window auto-start.
///
/// Lives for the lifetime of the app so closing the menu-bar popover never stops
/// monitoring. Every decision is taken by `UsageWindowStartPolicy`; every state
/// change goes through `UsageWindowStartTransitions`; the cross-instance lock is
/// held by `UsageWindowStartStore`. This type only sequences those pieces and
/// owns the deadline timer.
final class UsageWindowStartService: ObservableObject {
    @Published private(set) var phase: UsageWindowStartPhase = .idle
    @Published private(set) var activity: UsageWindowActivity = .unknown
    @Published private(set) var blockReason: UsageWindowStartBlockReason?
    @Published private(set) var nextCheckDate: Date?
    @Published private(set) var lastOutcomeCode: UsageWindowStartOutcomeCode?
    @Published private(set) var lastFailureCode: UsageWindowStartFailureCode?
    @Published private(set) var lastOutcomeAt: Date?
    @Published private(set) var settings: UsageWindowStartSettings = .defaultValue
    @Published private(set) var models: [CodexModelSummary] = []
    @Published private(set) var isModelCatalogLoading = false
    /// True when the duplicate-protection file cannot be trusted. Automatic
    /// sending stays paused until the user resolves the file.
    @Published private(set) var protectionError: UsageWindowStartStoreError?
    @Published private(set) var isSending = false
    @Published private(set) var isChecking = false
    /// True when a settings change could not be written, so the UI does not
    /// pretend a preference was saved.
    @Published private(set) var settingsSaveFailed = false

    private let usage: CodexUsageService
    private let store: UsageWindowStartStore
    private let runner: WindowStartRunning
    private let appSettings: AppSettings
    private let clock: () -> Date
    private let calendar: () -> Calendar

    private var accountKey: String?
    private var state = UsageWindowStartState.empty
    private var previousObservation: UsageWindowObservation?
    private var deadlineTimer: Timer?
    private var modelCatalogFailures = 0
    /// Set when the account changed while a request was in flight. The record is
    /// reloaded once that request settles, so the app never keeps showing the
    /// previous account's switch and schedule.
    private var pendingAccountReload = false
    private var lastModelCatalogAttempt: Date?
    private var modelCatalogRequestID: UUID?
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// Consecutive read-only rechecks that have not produced a new reset.
    private var readOnlyRetryCount = 0

    init(
        usage: CodexUsageService,
        appSettings: AppSettings,
        store: UsageWindowStartStore = UsageWindowStartStore(),
        runner: WindowStartRunning? = nil,
        clock: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { .autoupdatingCurrent }
    ) {
        self.usage = usage
        self.appSettings = appSettings
        self.store = store
        self.clock = clock
        self.calendar = calendar
        self.runner = runner ?? CodexWindowStartRunner(
            transport: CodexAppServerWindowStartTransport(
                usage: usage,
                workDirectory: store.pingDirectoryURL
            )
        )

        // Create the support folder and the empty request working directory up
        // front so a send never fails on a missing directory.
        try? store.prepareDirectories()

        observeUsage()
        observeSystemEvents()
        reloadAccountRecord()
    }

    // MARK: - Derived presentation

    /// True while an attempt reserves the right to send and has not been resolved.
    var hasOpenAttempt: Bool {
        UsageWindowStartTransitions.hasUnresolvedAttempt(state)
    }

    var canClearProtection: Bool {
        state.lastOutcomeCode == .deliveryUnknown || state.phase == .unconfirmed
    }

    var selectedModel: CodexModelSummary? {
        guard let modelID = settings.modelID else { return nil }
        return models.first { $0.id == modelID }
    }

    var availableEfforts: [String] {
        selectedModel?.supportedReasoningEfforts ?? []
    }

    /// Both automation switches require a model and a still-supported effort.
    var canEnableAutomation: Bool {
        guard canEditSettings, let model = selectedModel else { return false }
        return UsageWindowReasoningPreference.resolved(
            stored: settings.reasoningEffort, model: model
        ) != nil
    }

    var canEditSettings: Bool {
        accountKey != nil && accountKey == usage.currentAccountKey
    }

    /// The model list plus the currently selected model even if it is hidden, so
    /// a hidden selection is never silently replaced.
    var selectableModels: [CodexModelSummary] {
        models.filter { !$0.isHidden || $0.id == settings.modelID }
    }

    // MARK: - User actions

    func startNow() {
        guard !isSending, !isChecking else { return }
        guard protectionError == nil else {
            blockReason = .protectionStateUnavailable
            return
        }

        isChecking = true
        phase = .checking
        blockReason = nil

        // Never trust the snapshot the button was rendered from.
        usage.requestFreshObservation { [weak self] observation in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.isChecking = false }

                guard let observation else {
                    self.phase = self.state.phase
                    self.blockReason = .observationUnavailable
                    self.armDeadline()
                    return
                }
                self.evaluate(using: observation, trigger: .manual)
            }
        }
    }

    func setAutoStartEnabled(_ enabled: Bool) {
        updateSettings { $0.autoStartEnabled = enabled }
        if !enabled {
            // A sent request keeps resolving: the confirmation deadline and the
            // cooldown stay armed so the delivery record stays honest.
            isChecking = false
        }
        armDeadline()
    }

    func setModel(_ modelID: String?) {
        updateSettings { settings in
            settings.modelID = modelID
            if let modelID, let model = models.first(where: { $0.id == modelID }) {
                settings.reasoningEffort = UsageWindowReasoningPreference.suggested(for: model)
            } else {
                settings.reasoningEffort = nil
            }
        }
    }

    func setReasoningEffort(_ effort: String?) {
        updateSettings { $0.reasoningEffort = effort }
    }

    func setActiveHoursEnabled(_ enabled: Bool) {
        updateSettings { settings in
            settings.activeHours.isEnabled = enabled
            if enabled, settings.activeHours.startMinutes == settings.activeHours.endMinutes {
                // Seeding equal minutes would read as "all day"; offer a usable
                // default range that the user can then adjust.
                settings.activeHours.startMinutes = 8 * 60
                settings.activeHours.endMinutes = 22 * 60
            }
        }
        armDeadline()
    }

    func setActiveHoursStart(minutes: Int) {
        updateSettings { $0.activeHours.startMinutes = minutes }
        armDeadline()
    }

    func setActiveHoursEnd(minutes: Int) {
        updateSettings { $0.activeHours.endMinutes = minutes }
        armDeadline()
    }

    /// Clears an unresolved protection record. This is deliberately not a
    /// resend: a later evaluation still has to prove the window is idle.
    func clearProtection() {
        guard let accountKey else { return }
        switch UsageWindowStartWrites.clearProtection(
            store: store,
            accountKey: accountKey,
            now: clock()
        ) {
        case let .written(cleared):
            state = cleared
            protectionError = nil
        case .superseded:
            break
        case let .unavailable(error):
            apply(storeError: error)
        }
        readOnlyRetryCount = 0
        phase = state.phase
        lastOutcomeCode = state.lastOutcomeCode
        lastFailureCode = state.lastFailureCode
        lastOutcomeAt = state.lastOutcomeAt
        armDeadline()
    }

    func refreshModelCatalog() {
        guard !isModelCatalogLoading else { return }
        guard let currentKey = usage.currentAccountKey else {
            usage.refreshAccount()
            return
        }
        guard accountKey == currentKey else {
            reloadAccountRecord()
            return
        }
        isModelCatalogLoading = true
        lastModelCatalogAttempt = clock()
        let generation = usage.accountGeneration
        let requestID = UUID()
        modelCatalogRequestID = requestID

        usage.requestModels { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.modelCatalogRequestID == requestID else { return }
                self.modelCatalogRequestID = nil
                self.isModelCatalogLoading = false
                guard self.usage.accountGeneration == generation else { return }

                switch result {
                case let .success(models):
                    self.models = models
                    self.modelCatalogFailures = 0
                case .failure:
                    // A catalog failure only affects the settings surface.
                    self.models = []
                    self.modelCatalogFailures += 1
                }
                self.armDeadline()
            }
        }
    }

    // MARK: - Lifecycle

    func teardown() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        runner.cancel()
        cancellables.removeAll()
        // Each token is removed from the center that delivered it.
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
    }

    private func observeUsage() {
        usage.$latestObservation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] observation in
                self?.handleObservationChanged(observation)
            }
            .store(in: &cancellables)

        usage.$accountGeneration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleAccountBoundary()
            }
            .store(in: &cancellables)
    }

    private func observeSystemEvents() {
        // `NSWorkspace` posts on its own center; observing its wake notification
        // on the application center silently never fires.
        for event in UsageWindowSystemNotification.allCases {
            observe(event)
        }

        let applicationCenter = NotificationCenter.default
        observers.append((
            applicationCenter,
            applicationCenter.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.teardown()
            }
        ))
    }

    private func observe(_ event: UsageWindowSystemNotification) {
        let center = Self.center(for: event.centerKind)
        let name: Notification.Name
        switch event {
        case .wake:
            name = NSWorkspace.didWakeNotification
        case .clockChange:
            name = .NSSystemClockDidChange
        case .timeZoneChange:
            name = .NSSystemTimeZoneDidChange
        }

        observers.append((
            center,
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Waking does not replay missed rounds; it only re-reads once.
                DispatchQueue.main.async { self?.handleSystemContextChanged() }
            }
        ))
    }

    private static func center(
        for kind: UsageWindowNotificationCenterKind
    ) -> NotificationCenter {
        switch kind {
        case .application:
            return .default
        case .workspace:
            return NSWorkspace.shared.notificationCenter
        }
    }

    private func handleSystemContextChanged() {
        armDeadline()
        guard settings.autoStartEnabled else { return }
        usage.requestFreshObservation { [weak self] observation in
            DispatchQueue.main.async {
                guard let self, let observation else { return }
                self.evaluate(using: observation, trigger: .automatic)
            }
        }
    }

    // MARK: - Account record

    private func handleAccountBoundary() {
        isChecking = false
        // Everything cached here belongs to the account that just ended.
        previousObservation = nil
        modelCatalogRequestID = nil
        isModelCatalogLoading = false
        models = []
        modelCatalogFailures = 0
        lastModelCatalogAttempt = nil
        pendingAccountReload = true

        if isSending {
            // The request already left the app. Wait for its result rather than
            // discarding the delivery record, then load the new account's record.
            armDeadline()
            return
        }
        reloadAccountRecord()
    }

    private func reloadAccountRecord() {
        pendingAccountReload = false
        let key = usage.currentAccountKey
        accountKey = key
        protectionError = nil

        guard let key else {
            state = .empty
            settings = .defaultValue
            publishState()
            armDeadline()
            return
        }

        do {
            let document = try store.snapshot()
            let record = document.record(for: key)
            state = record.state
            settings = record.settings
        } catch let error as UsageWindowStartStoreError {
            // A corrupt or future-schema file pauses automatic sending instead
            // of being cleared and re-created.
            protectionError = error
            state = .empty
            settings = .defaultValue
        } catch {
            protectionError = .unreadable
            state = .empty
            settings = .defaultValue
        }

        publishState()
        refreshModelCatalog()
        armDeadline()
    }

    private func updateSettings(_ transform: (inout UsageWindowStartSettings) -> Void) {
        guard let accountKey else { return }
        let previous = settings
        var updated = settings
        transform(&updated)
        settings = updated

        do {
            try store.transaction { document in
                var record = document.record(for: accountKey)
                record.settings = updated
                record.updatedAt = self.clock()
                document.accounts[accountKey] = record
            }
            settingsSaveFailed = false
        } catch {
            // Snap the control back instead of advertising a preference that was
            // never written. Automatic sending is not paused for this: only the
            // duplicate-protection document gates sending.
            settings = previous
            settingsSaveFailed = true
        }
    }

    // MARK: - Observation handling

    private func handleObservationChanged(_ observation: UsageWindowObservation?) {
        guard let observation else {
            activity = .unknown
            armDeadline()
            return
        }
        // A response from a previous account must not touch this account's record.
        guard observation.accountGeneration == usage.accountGeneration,
              observation.accountKey == usage.currentAccountKey else {
            return
        }

        previousObservation = usage.previousObservation
        let resolvedActivity = UsageWindowStartPolicy.activity(
            observation: observation,
            previousObservation: previousObservation,
            now: clock()
        )
        activity = resolvedActivity

        reconcileActivity(resolvedActivity, at: clock(), observedAt: observation.observedAt)

        retryModelCatalogIfNeeded()

        guard settings.autoStartEnabled,
              !isSending,
              !isChecking,
              protectionError == nil,
              !observation.isOlderThan(
                  UsageWindowStartSchedule.confirmationDelay + 30,
                  now: clock()
              ) else {
            armDeadline()
            return
        }

        evaluate(using: observation, trigger: .automatic)
    }

    /// The catalog is requested before the App Server is ready at launch, so it
    /// is retried on later observations until it succeeds.
    private func retryModelCatalogIfNeeded() {
        guard models.isEmpty, !isModelCatalogLoading else { return }
        let retryDelay: TimeInterval = modelCatalogFailures >= 3 ? 300 : 60
        if let lastModelCatalogAttempt,
           clock().timeIntervalSince(lastModelCatalogAttempt) < retryDelay {
            return
        }
        refreshModelCatalog()
    }

    private func reconcileActivity(
        _ activity: UsageWindowActivity,
        at now: Date,
        observedAt: Date
    ) {
        guard UsageWindowStartTransitions.hasUnresolvedAttempt(state) else { return }
        guard let accountKey else { return }

        switch UsageWindowStartWrites.reconcile(
            activity: activity,
            store: store,
            accountKey: accountKey,
            now: now,
            observedAt: observedAt
        ) {
        case let .written(updated):
            state = updated
            protectionError = nil
        case .superseded:
            break
        case let .unavailable(error):
            apply(storeError: error)
        }
        publishState()
    }

    // MARK: - Evaluation

    /// Runs the whole decision inside the store transaction.
    ///
    /// Deciding from memory and then writing the result let a second running copy
    /// pass its own stale check and reserve too. The reservation now re-reads the
    /// persisted record under the lock, so a concurrent attempt is rejected
    /// instead of overwritten.
    private func evaluate(using observation: UsageWindowObservation, trigger: UsageWindowStartTrigger) {
        guard let accountKey, accountKey == usage.currentAccountKey else {
            blockReason = .accountChanged
            armDeadline()
            return
        }
        guard protectionError == nil else {
            blockReason = .protectionStateUnavailable
            armDeadline()
            return
        }

        let request = UsageWindowStartReservationRequest(
            accountKey: accountKey,
            observation: observation,
            previousObservation: previousObservation,
            currentAccountGeneration: usage.accountGeneration,
            currentAccountType: usage.accountType,
            models: models,
            now: clock(),
            calendar: calendar(),
            trigger: trigger,
            isPreviewMode: appSettings.developerPreviewEnabled
        )

        switch UsageWindowStartReserver.reserve(store: store, request: request) {
        case let .reserved(attemptID, reserved, persistedSettings):
            state = reserved
            settings = persistedSettings
            protectionError = nil
            publishState()
            dispatch(attemptID: attemptID, settings: persistedSettings, observation: observation)

        case let .rejected(reason):
            blockReason = reason
            phase = state.phase
            refreshAccountState()
            armDeadline()

        case let .unavailable(error):
            // A lock conflict is transient: another copy is inside a transaction
            // right now. Only an unusable file should pause the feature.
            if error == .lockUnavailable {
                blockReason = .anotherInstanceActive
            } else {
                protectionError = error
                blockReason = .protectionStateUnavailable
            }
            publishState()
            armDeadline()
        }
    }

    private func dispatch(
        attemptID: String,
        settings persistedSettings: UsageWindowStartSettings,
        observation: UsageWindowObservation
    ) {
        guard let modelID = persistedSettings.modelID,
              let model = models.first(where: { $0.id == modelID }),
              let effort = UsageWindowReasoningPreference.resolved(
                  stored: persistedSettings.reasoningEffort,
                  model: model
              ),
              observation.shortWindow?.windowIdentity != nil else {
            // The record authorized a send the catalog cannot build. Close the
            // reservation instead of leaving the episode open forever.
            abandonReservation(attemptID: attemptID, reason: .modelRejected)
            return
        }

        isSending = true
        phase = .sending
        blockReason = nil

        let request = WindowStartRequest(
            modelID: modelID,
            reasoningEffort: effort,
            timeout: CodexWindowStartRunner.defaultTimeout,
            attemptID: attemptID
        )

        runner.start(request) { [weak self] outcome in
            DispatchQueue.main.async {
                self?.handleSendOutcome(outcome, attemptID: attemptID)
            }
        }
    }

    /// Resolves a reservation that never reached the transport, so its duplicate
    /// protection cannot block the next evaluation indefinitely.
    private func abandonReservation(
        attemptID: String,
        reason: UsageWindowStartFailureCode
    ) {
        isSending = false
        guard let accountKey else {
            armDeadline()
            return
        }
        if case let .written(state) = UsageWindowStartWrites.applySendOutcome(
            .failed(reason),
            attemptID: attemptID,
            store: store,
            accountKey: accountKey,
            now: clock()
        ) {
            self.state = state
        }
        blockReason = .modelUnavailable
        publishState()
        armDeadline()
    }

    private func handleSendOutcome(_ outcome: WindowStartOutcome, attemptID: String) {
        isSending = false

        // The account changed mid-flight. The old account's record already keeps
        // its own protection on disk; this process must now switch to the new one.
        if pendingAccountReload || accountKey != usage.currentAccountKey {
            reloadAccountRecord()
            return
        }
        guard let accountKey else {
            armDeadline()
            return
        }

        switch UsageWindowStartWrites.applySendOutcome(
            outcome,
            attemptID: attemptID,
            store: store,
            accountKey: accountKey,
            now: clock()
        ) {
        case let .written(updated):
            state = updated
            protectionError = nil
        case .superseded:
            // A newer attempt owns the record; this result is irrelevant now.
            break
        case let .unavailable(error):
            apply(storeError: error)
        }

        publishState()

        // A delivered turn keeps reading only: arrival is proven, a started
        // window is not, and the confirmation deadline does the settling.
        armDeadline()
    }

    /// Records a store failure. A momentary lock conflict is left to the next
    /// evaluation so a second running copy cannot pause this one permanently.
    private func apply(storeError: UsageWindowStartStoreError) {
        guard storeError != .lockUnavailable else { return }
        protectionError = storeError
    }

    /// Reads the current account's record without touching the model catalog or
    /// the deadline schedule.
    private func refreshAccountState() {
        guard let accountKey else { return }
        do {
            let record = try store.snapshot().record(for: accountKey)
            state = record.state
            settings = record.settings
        } catch let error as UsageWindowStartStoreError {
            protectionError = error
        } catch {
            protectionError = .unreadable
        }
    }

    // MARK: - Confirmation

    private func performConfirmation() {
        guard !isChecking, let accountKey, let attemptID = state.attemptID else { return }
        isChecking = true
        let generation = usage.accountGeneration

        usage.requestFreshObservation { [weak self] observation in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.isChecking = false }

                // An answer that belongs to a superseded account or attempt is
                // not evidence about this attempt.
                guard self.usage.accountGeneration == generation,
                      self.accountKey == accountKey,
                      self.state.attemptID == attemptID else {
                    self.armDeadline()
                    return
                }

                guard let observation else {
                    // A missing read is not evidence that no window started.
                    // Keep waiting and re-arm; the UI reports the failed read.
                    self.armDeadline()
                    return
                }

                self.previousObservation = self.usage.previousObservation
                let resolved = UsageWindowStartPolicy.activity(
                    observation: observation,
                    previousObservation: self.previousObservation,
                    now: self.clock()
                )
                self.activity = resolved

                switch UsageWindowStartWrites.settleConfirmation(
                    attemptID: attemptID,
                    confirmed: resolved == .active,
                    store: self.store,
                    accountKey: accountKey,
                    now: self.clock()
                ) {
                case let .written(settled):
                    self.state = settled
                    self.protectionError = nil
                case .superseded:
                    break
                case let .unavailable(error):
                    self.apply(storeError: error)
                }

                self.publishState()
                self.armDeadline()
            }
        }
    }

    // MARK: - Scheduling

    private func armDeadline() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil

        if pendingAccountReload, !isSending {
            reloadAccountRecord()
            return
        }

        if protectionError == .lockUnavailable, !isSending {
            // Another copy held the lock while this one tried to load its record.
            // Retry on the bounded cadence rather than staying paused.
            if readOnlyRetryCount >= UsageWindowStartSchedule.maximumStaleRetries {
                nextCheckDate = nil
                return
            }
            readOnlyRetryCount += 1
            scheduleTimer(after: UsageWindowStartSchedule.staleRetryDelay, at: clock())
            return
        }

        guard protectionError == nil, let accountKey, accountKey == usage.currentAccountKey else {
            nextCheckDate = nil
            return
        }

        let now = clock()
        var next = UsageWindowStartSchedule.nextDeadline(
            observation: usage.latestObservation,
            settings: settings,
            state: state,
            now: now,
            calendar: calendar()
        )

        // A confirmation that came due while the app was closed, or a read that
        // failed, is retried on the bounded read cadence. Resolving it here
        // instead would recurse for as long as reads keep failing.
        if state.phase == .awaitingConfirmation,
           let confirmationDeadline = state.confirmationDeadline,
           confirmationDeadline <= now {
            let retryDate = now.addingTimeInterval(UsageWindowStartSchedule.staleRetryDelay)
            if next == nil || next!.date > retryDate {
                next = UsageWindowStartDeadline(
                    date: retryDate,
                    reason: .confirmation,
                    isRetry: true
                )
            }
        }

        // Read-only rechecks are capped; after that the ordinary periodic refresh
        // takes over instead of a short timer that never advances.
        if let candidate = next, candidate.isRetry {
            if readOnlyRetryCount >= UsageWindowStartSchedule.maximumStaleRetries {
                nextCheckDate = nil
                return
            }
            readOnlyRetryCount += 1
        } else {
            readOnlyRetryCount = 0
        }

        nextCheckDate = next?.date

        guard let next else { return }
        scheduleTimer(after: next.date.timeIntervalSince(now), at: now)
    }

    private func scheduleTimer(after interval: TimeInterval, at now: Date) {
        deadlineTimer?.invalidate()
        nextCheckDate = now.addingTimeInterval(max(1, interval))
        let timer = Timer(timeInterval: max(1, interval), repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.handleDeadline() }
        }
        timer.tolerance = min(5, max(1, interval) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func handleDeadline() {
        deadlineTimer = nil

        if protectionError == .lockUnavailable, !isSending {
            reloadAccountRecord()
            return
        }

        let now = clock()
        if state.phase == .awaitingConfirmation,
           let confirmationDeadline = state.confirmationDeadline,
           confirmationDeadline <= now {
            // Confirmation keeps running after automatic start is switched off:
            // a request that already left the app still needs an observed result.
            performConfirmation()
            return
        }

        guard settings.autoStartEnabled, !isSending, !isChecking else {
            armDeadline()
            return
        }
        isChecking = true

        usage.requestFreshObservation { [weak self] observation in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.isChecking = false }

                guard let observation else {
                    self.armDeadline()
                    return
                }
                self.evaluate(using: observation, trigger: .automatic)
            }
        }
    }

    private func publishState() {
        phase = state.phase
        lastOutcomeCode = state.lastOutcomeCode
        lastFailureCode = state.lastFailureCode
        lastOutcomeAt = state.lastOutcomeAt
    }
}

/// Adapts the shared, already authenticated App Server connection to the runner's
/// transport seam.
final class CodexAppServerWindowStartTransport: WindowStartTransport {
    private weak var usage: CodexUsageService?
    private let workDirectory: URL

    init(usage: CodexUsageService, workDirectory: URL) {
        self.usage = usage
        self.workDirectory = workDirectory
    }

    func startEphemeralTurn(
        _ request: WindowStartRequest,
        completion: @escaping (WindowStartTransportResult) -> Void
    ) {
        guard let usage else {
            completion(.rejected(.notAuthenticated))
            return
        }
        usage.startEphemeralWindowTurn(
            model: request.modelID,
            reasoningEffort: request.reasoningEffort,
            prompt: request.prompt,
            workDirectory: workDirectory,
            attemptID: request.attemptID,
            completion: completion
        )
    }

    func cancelPendingTurn(attemptID: String) {
        usage?.cancelEphemeralWindowTurn(attemptID: attemptID)
    }
}
