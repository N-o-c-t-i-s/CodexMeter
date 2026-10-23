import SwiftUI

/// Compact status and automation switch; detailed configuration stays in Settings.
struct UsageWindowStartPanel: View {
    @Binding var autoStartEnabled: Bool
    let status: String
    let statusSymbol: String
    let isFailure: Bool
    let detail: String?
    let runningWindowReset: Date?
    let model: String
    let activeHours: String
    let nextCheck: Date?
    var timeTint: Color = .accentColor
    var canEnableAutomation = true
    let openSettings: () -> Void

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            content(at: context.date)
        }
    }

    private func content(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(L10n.string("windowstart.panel.title"), systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Toggle(
                    L10n.string("windowstart.settings.auto_start"),
                    isOn: $autoStartEnabled
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!autoStartEnabled && !canEnableAutomation)
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(status, systemImage: statusSymbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isFailure ? Color.orange : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let reset = runningWindowReset, reset > now {
                VStack(alignment: .trailing, spacing: 5) {
                    MetricBar(
                        label: L10n.string("windowstart.panel.remaining"),
                        value: min(100, max(0, reset.timeIntervalSince(now) / (300 * 60) * 100)),
                        tint: timeTint,
                        symbol: "clock"
                    )
                    Text(L10n.remainingDuration(until: reset, from: now))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if autoStartEnabled, let nextCheck {
                summaryRow(
                    "clock",
                    label: L10n.string("windowstart.settings.status_next_check"),
                    value: L10n.formattedDateTime(nextCheck)
                )
            }

            Divider()

            VStack(spacing: 6) {
                summaryRow("cpu", label: L10n.string("windowstart.settings.model"), value: model)
                summaryRow("calendar", label: L10n.string("windowstart.panel.hours"), value: activeHours)
            }

            HStack {
                Spacer()
                Button(action: openSettings) {
                    Label(L10n.string("windowstart.action.settings"), systemImage: "gearshape")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.primary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryRow(_ symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Label(label, systemImage: symbol)
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 6)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }
}
