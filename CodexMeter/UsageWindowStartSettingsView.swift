import SwiftUI

/// Localized presentation for the window starter's encoded state.
enum UsageWindowStartText {
    static func activity(_ activity: UsageWindowActivity) -> String {
        L10n.string("windowstart.activity.\(activity.rawValue)")
    }

    static func phase(_ phase: UsageWindowStartPhase) -> String {
        L10n.string("windowstart.phase.\(phase.rawValue)")
    }

    static func reason(_ reason: UsageWindowStartBlockReason) -> String {
        L10n.string("windowstart.reason.\(reason.rawValue)")
    }

    static func outcome(_ code: UsageWindowStartOutcomeCode) -> String {
        L10n.string("windowstart.outcome.\(code.rawValue)")
    }

    static func failure(_ code: UsageWindowStartFailureCode) -> String {
        L10n.string("windowstart.failure.\(code.rawValue)")
    }

    /// The automatic-state line: switch state first, then the blocking reason.
    static func automaticState(
        settings: UsageWindowStartSettings,
        reason: UsageWindowStartBlockReason?
    ) -> String {
        guard settings.autoStartEnabled else {
            return L10n.string("windowstart.automatic.off")
        }
        guard let reason else {
            return L10n.string("windowstart.automatic.on")
        }
        return Self.reason(reason)
    }

    /// The execution line shown while an attempt is running or settled.
    static func executionState(
        phase: UsageWindowStartPhase,
        activity: UsageWindowActivity,
        outcome: UsageWindowStartOutcomeCode?,
        failure: UsageWindowStartFailureCode?
    ) -> String {
        switch phase {
        case .checking, .sending, .awaitingConfirmation:
            return self.phase(phase)
        case .idle:
            return self.activity(activity)
        case .confirmed, .unconfirmed, .failed:
            if let outcome {
                let base = self.outcome(outcome)
                if let failure, outcome == .failed || outcome == .deliveryUnknown {
                    return L10n.format("windowstart.outcome_with_reason_format", base, self.failure(failure))
                }
                return base
            }
            return self.phase(phase)
        }
    }
}

/// Model, reasoning effort, daily range, and the latest structured result.
///
/// Shared by the Settings category and the popover's independent window, so
/// controls remain usable after the menu-bar popover loses focus.
struct UsageWindowStartSettingsView: View {
    @ObservedObject var service: UsageWindowStartService
    @ObservedObject var settings: AppSettings
    @ObservedObject var usage: CodexUsageService
    @State private var isConfirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                automaticSection
                Divider()
                modelSection
                Divider()
                scheduleSection
                Divider()
                statusSection
                Divider()
                protectionSection
                Divider()
                footer
            }
            .padding(20)
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        .onAppear { service.refreshModelCatalog() }
        .alert(
            L10n.string("windowstart.settings.clear_confirm_title"),
            isPresented: $isConfirmingClear
        ) {
            Button(L10n.string("windowstart.settings.clear"), role: .destructive) {
                service.clearProtection()
            }
            Button(L10n.string("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("windowstart.settings.clear_confirm_message"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("windowstart.settings.title"))
                .font(.title3.weight(.semibold))
            Text(L10n.string("windowstart.help"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var automaticSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                L10n.string("windowstart.settings.auto_start"),
                isOn: Binding(
                    get: { service.settings.autoStartEnabled },
                    set: { service.setAutoStartEnabled($0) }
                )
            )
            .disabled(!service.settings.autoStartEnabled && !service.canEnableAutomation)

            Text(L10n.string("windowstart.settings.auto_start_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !service.canEnableAutomation {
                Label(
                    L10n.string(service.canEditSettings
                        ? "windowstart.settings.needs_model"
                        : "windowstart.settings.account_unavailable"),
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.string("windowstart.settings.model"))
                Spacer()
                if service.isModelCatalogLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.string("windowstart.settings.reload_models")) {
                        service.refreshModelCatalog()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if service.selectableModels.isEmpty {
                Text(service.isModelCatalogLoading
                    ? L10n.string("windowstart.settings.loading")
                    : L10n.string("windowstart.settings.models_unavailable"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(
                    L10n.string("windowstart.settings.model"),
                    selection: Binding(
                        get: { service.settings.modelID },
                        set: { service.setModel($0) }
                    )
                ) {
                    Text(L10n.string("windowstart.settings.model_none")).tag(String?.none)
                    ForEach(service.selectableModels) { model in
                        Text(model.displayName).tag(String?.some(model.id))
                    }
                }
                .labelsHidden()
                .disabled(!service.canEditSettings)
            }

            if !service.availableEfforts.isEmpty {
                Picker(
                    L10n.string("windowstart.settings.effort"),
                    selection: Binding(
                        get: { service.settings.reasoningEffort },
                        set: { service.setReasoningEffort($0) }
                    )
                ) {
                    ForEach(service.availableEfforts, id: \.self) { effort in
                        Text(effort).tag(String?.some(effort))
                    }
                }
            }

            Text(L10n.string("windowstart.settings.model_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(
                L10n.string("windowstart.settings.hours"),
                isOn: Binding(
                    get: { service.settings.activeHours.isEnabled },
                    set: { service.setActiveHoursEnabled($0) }
                )
            )

            if service.settings.activeHours.isEnabled {
                // Both pickers stay editable even while the range reads as "all
                // day", so the user can type a range instead of toggling twice.
                HStack(spacing: 16) {
                    timePicker(
                        L10n.string("windowstart.settings.hours_from"),
                        minutes: service.settings.activeHours.startMinutes
                    ) { service.setActiveHoursStart(minutes: $0) }

                    timePicker(
                        L10n.string("windowstart.settings.hours_to"),
                        minutes: service.settings.activeHours.endMinutes
                    ) { service.setActiveHoursEnd(minutes: $0) }
                }

                if service.settings.activeHours.isAllDay {
                    Text(L10n.string("windowstart.settings.hours_allday"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if service.settings.activeHours.startMinutes
                            > service.settings.activeHours.endMinutes {
                    Text(L10n.string("windowstart.settings.hours_crosses_midnight"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(L10n.string("windowstart.settings.hours_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("windowstart.settings.status"))
                .font(.headline)

            HStack(spacing: 8) {
                Button(L10n.string("windowstart.action.start_now")) {
                    service.startNow()
                }
                .buttonStyle(.bordered)
                .disabled(service.isSending || service.isChecking)

                if service.isSending || service.isChecking {
                    ProgressView().controlSize(.small)
                }
            }

            labelledRow(
                L10n.string("windowstart.settings.status_automatic"),
                UsageWindowStartText.automaticState(
                    settings: service.settings,
                    reason: service.blockReason
                )
            )

            labelledRow(
                L10n.string("windowstart.settings.status_execution"),
                UsageWindowStartText.executionState(
                    phase: service.phase,
                    activity: service.activity,
                    outcome: service.lastOutcomeCode,
                    failure: service.lastFailureCode
                )
            )

            labelledRow(
                L10n.string("windowstart.settings.status_next_check"),
                nextCheckText
            )

            if let lastOutcomeAt = service.lastOutcomeAt {
                labelledRow(
                    L10n.string("windowstart.settings.status_last_result"),
                    L10n.formattedDateTime(lastOutcomeAt)
                )
            }

            if service.settingsSaveFailed {
                Label(
                    L10n.string("windowstart.settings.save_failed"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let protectionError = service.protectionError {
                Label(
                    L10n.format(
                        "windowstart.settings.protection_error_format",
                        protectionErrorDescription(protectionError)
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var protectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(L10n.string("windowstart.settings.clear")) {
                isConfirmingClear = true
            }
            .disabled(!service.canClearProtection)

            Text(L10n.string("windowstart.settings.clear_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("windowstart.settings.only_one"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.string("windowstart.settings.sleep"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers

    private var nextCheckText: String {
        guard service.settings.autoStartEnabled else {
            return L10n.string("windowstart.settings.status_none")
        }
        guard let nextCheckDate = service.nextCheckDate else {
            return L10n.string("windowstart.settings.status_none")
        }
        return L10n.formattedDateTime(nextCheckDate)
    }

    private func protectionErrorDescription(_ error: UsageWindowStartStoreError) -> String {
        switch error {
        case .lockUnavailable:
            return L10n.string("windowstart.settings.protection_lock")
        case .unsupportedSchema:
            return L10n.string("windowstart.settings.protection_schema")
        case .corrupt, .unreadable, .oversized:
            return L10n.string("windowstart.settings.protection_corrupt")
        case .writeFailed:
            return L10n.string("windowstart.settings.protection_write")
        }
    }

    private func labelledRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func timePicker(
        _ label: String,
        minutes: Int,
        onChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            DatePicker(
                label,
                selection: Binding(
                    get: { Self.date(fromMinutes: minutes) },
                    set: { onChange(Self.minutes(from: $0)) }
                ),
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
        }
    }

    private static func date(fromMinutes minutes: Int) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let startOfDay = calendar.startOfDay(for: Date())
        return calendar.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: startOfDay
        ) ?? startOfDay
    }

    private static func minutes(from date: Date) -> Int {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
